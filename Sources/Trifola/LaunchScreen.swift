import SwiftUI
import AppKit
import TrifolaKit

// MARK: - Store
// The LAUNCH pillar's app-side state: saved recipes (JSON in the app's OWN dir,
// never ~/.claude) + composition/spawn plumbing. Composition itself is pure and
// tested in TrifolaKit; this store only persists, materializes the
// system-prompt hint file, and talks to the clipboard.

@MainActor
final class LaunchStore: ObservableObject {
    @Published private(set) var recipes: [Recipe] = []
    @Published private(set) var persistenceError: String?
    let repo: RecipeRepository
    private var persistenceRetry: (() -> Void)?

    var persistenceLocation: URL { repo.directory }

    init(repo: RecipeRepository = RecipeRepository()) {
        self.repo = repo
    }

    func reload() {
        recipes = repo.list()
    }

    @discardableResult
    func save(_ recipe: Recipe) -> Recipe? {
        var r = recipe
        r.updatedAt = Date()
        do {
            try repo.save(r)
        } catch {
            recordPersistenceFailure(
                "Recipe was not saved at \(repo.recipeURL(r.id).path): \(error.localizedDescription)") { [weak self] in
                    _ = self?.save(r)
                }
            return nil
        }
        reload()
        clearPersistenceFailure()
        do {
            _ = try repo.materializePrompt(r)
        } catch {
            recordPersistenceFailure(
                "Recipe saved, but its skill-hint file was not written: \(error.localizedDescription)") { [weak self] in
                    self?.retryPromptMaterialization(r)
                }
        }
        return r
    }

    func delete(_ id: String) { repo.delete(id); reload() }

    @discardableResult
    func duplicate(_ recipe: Recipe) -> Recipe? {
        var copy = recipe
        copy.id = UUID().uuidString
        copy.name = recipe.name + " copy"
        copy.createdAt = Date(); copy.updatedAt = Date()
        do {
            try repo.save(copy)
        } catch {
            recordPersistenceFailure(
                "Recipe copy was not saved at \(repo.recipeURL(copy.id).path): \(error.localizedDescription)") { [weak self] in
                    _ = self?.duplicatePersisting(copy)
                }
            return nil
        }
        reload()
        clearPersistenceFailure()
        return copy
    }

    /// Compose with the REAL materialized prompt-file path (writes the file when
    /// the recipe has skill refs) — the exact command a launch/copy uses.
    func compose(_ recipe: Recipe) -> RecipeCommand {
        let path: String?
        do {
            path = try repo.materializePrompt(recipe)
        } catch {
            path = nil
            recordPersistenceFailure(
                "Launch command omitted the skill-hint file because it could not be written: \(error.localizedDescription)") { [weak self] in
                    self?.retryPromptMaterialization(recipe)
                }
        }
        return RecipeComposer.compose(recipe, promptFilePath: path)
    }

    /// The stable path the append-flag WILL point at — shown in the live preview
    /// before the file is written, so the command block is never a black box.
    func previewPromptPath(_ recipe: Recipe) -> String? {
        RecipeComposer.systemPromptText(recipe).isEmpty ? nil : repo.promptURL(recipe.id).path
    }

    func copyToClipboard(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    func retryPersistence() {
        persistenceRetry?()
    }

    private func duplicatePersisting(_ copy: Recipe) -> Recipe? {
        do {
            try repo.save(copy)
            reload()
            clearPersistenceFailure()
            return copy
        } catch {
            recordPersistenceFailure(
                "Recipe copy still could not be saved: \(error.localizedDescription)") { [weak self] in
                    _ = self?.duplicatePersisting(copy)
                }
            return nil
        }
    }

    private func retryPromptMaterialization(_ recipe: Recipe) {
        do {
            _ = try repo.materializePrompt(recipe)
            clearPersistenceFailure()
        } catch {
            recordPersistenceFailure(
                "Skill-hint file still could not be written: \(error.localizedDescription)") { [weak self] in
                    self?.retryPromptMaterialization(recipe)
                }
        }
    }

    private func recordPersistenceFailure(_ message: String,
                                          retry: @escaping () -> Void) {
        persistenceError = message
        persistenceRetry = retry
    }

    private func clearPersistenceFailure() {
        persistenceError = nil
        persistenceRetry = nil
    }
}

// MARK: - Screen

struct LaunchScreen: View {
    @EnvironmentObject var services: AppServices
    @State private var draft = Recipe.blank()
    @State private var feedback: String? = nil
    @State private var editingID: String? = nil    // non-nil = editing a saved recipe

    private var store: LaunchStore { services.launch }

    // Compose with the preview path (honest about where the hint file lands).
    private var command: RecipeCommand {
        RecipeComposer.compose(draft, promptFilePath: store.previewPromptPath(draft))
    }

    var body: some View {
        ScreenScaffold(
            title: "Launch",
            subtitle: "Compose a recipe — cwd, agents pinned to a model, effort, skills, MCP — then copy the one-liner. Start the next session right.",
            trailing: { headerActions }
        ) {
            HStack(alignment: .top, spacing: Theme.gutter) {
                builder.frame(maxWidth: .infinity, alignment: .leading)
                rightColumn.frame(width: 430)
            }
        }
        .overlay(alignment: .top) {
            if let feedback {
                Toast(text: feedback)
                    .id(feedback)
                    .padding(.top, Theme.intraCell)
            }
        }
        .motion(Theme.Motion.move, value: feedback)
        .task { await services.skills.refreshIfStale() }
        .onAppear(perform: consumeSeed)
        .onChange(of: services.pendingSkillSeed) { _, _ in consumeSeed() }
    }

    // A skill's Launch button seeded us — fold it into the draft.
    private func consumeSeed() {
        guard let ref = services.pendingSkillSeed else { return }
        if !draft.skillRefs.contains(ref) { draft.skillRefs.append(ref) }
        if draft.leadSkill == nil { draft.leadSkill = ref }
        services.pendingSkillSeed = nil
        flash("Seeded builder with /\(ref)")
    }

    private var headerActions: some View {
        HStack(spacing: 8) {
            QuietTapButton(action: {
                draft = Recipe.blank(); editingID = nil
            }) { Label("New", systemImage: "plus") }
        }
    }

    // MARK: Builder form

    private var builder: some View {
        VStack(alignment: .leading, spacing: Theme.gutter) {
            nameAndDir
            Divider()
            AgentsEditor(agents: $draft.agents)
            Divider()
            effortAndPermission
            Divider()
            SkillsEditor(draft: $draft, catalog: services.skills.allSkills)
            Divider()
            mcpAndSettings
        }
    }

    private var nameAndDir: some View {
        VStack(alignment: .leading, spacing: Theme.sectionGap) {
            SectionLabel("Recipe")
            LabeledField("Name") {
                TextField("e.g. release-notes run", text: $draft.name)
                    .textFieldStyle(.plain).font(.subheadline).foregroundStyle(Theme.ink)
            }
            LabeledField("Working dir") {
                HStack(spacing: 6) {
                    TextField("~/Developer/project", text: $draft.cwd)
                        .textFieldStyle(.plain).font(.subheadline).foregroundStyle(Theme.ink)
                    QuietTapButton("Choose…") { chooseDir { draft.cwd = $0 } }
                }
            }
            DirListEditor(title: "Extra CLAUDE.md dirs (--add-dir)", dirs: $draft.addDirs)
        }
    }

    private var effortAndPermission: some View {
        VStack(alignment: .leading, spacing: Theme.sectionGap) {
            SectionLabel("Effort & permissions")
            HStack(alignment: .top, spacing: Theme.gutter) {
                VStack(alignment: .leading, spacing: 5) {
                    Text("Effort (--effort)").font(.caption).foregroundStyle(Theme.muted)
                    Picker("", selection: $draft.effort) {
                        ForEach(EffortLevel.allCases, id: \.self) { Text($0.label).tag($0) }
                    }
                    .labelsHidden().pickerStyle(.segmented).frame(width: 320)
                    if draft.effort.isFurnace {
                        HStack(spacing: Theme.rhythm) {
                            Image(systemName: "flame")
                                .font(.caption2.weight(.medium))
                                .foregroundStyle(Theme.amber)
                            Text("xhigh/max asks the model to spend more compute; reserve it for unusually hard work.")
                                .font(.caption2)
                                .foregroundStyle(Theme.muted)
                        }
                    }
                }
                VStack(alignment: .leading, spacing: 5) {
                    Text("Permission mode").font(.caption).foregroundStyle(Theme.muted)
                    Picker("", selection: $draft.permissionMode) {
                        ForEach(PermissionMode.allCases, id: \.self) { Text($0.label).tag($0) }
                    }
                    .labelsHidden().frame(width: 190)
                    if draft.permissionMode.isLoose {
                        HStack(spacing: Theme.rhythm) {
                            Image(systemName: "exclamationmark.triangle")
                                .font(.caption2.weight(.medium))
                                .foregroundStyle(Theme.amber)
                            Text("Skips permission prompts — use only in a sandbox.")
                                .font(.caption2)
                                .foregroundStyle(Theme.muted)
                        }
                    }
                }
                TapToggle(isOn: $draft.background, mini: true) {
                    Text("Background (--bg)").font(.caption).foregroundStyle(Theme.muted)
                }
            }
        }
    }

    private var mcpAndSettings: some View {
        VStack(alignment: .leading, spacing: Theme.sectionGap) {
            SectionLabel("MCP & settings")
            LabeledField("MCP config (--mcp-config)") {
                PathField(path: Binding(get: { draft.mcpConfigPath ?? "" },
                                        set: { draft.mcpConfigPath = $0.isEmpty ? nil : $0 }),
                          placeholder: ".mcp.json", chooseFile: true)
            }
            LabeledField("Settings (--settings)") {
                PathField(path: Binding(get: { draft.settingsPath ?? "" },
                                        set: { draft.settingsPath = $0.isEmpty ? nil : $0 }),
                          placeholder: "settings.json", chooseFile: true)
            }
        }
    }

    // MARK: Right column — command preview + actions + saved recipes

    private var rightColumn: some View {
        VStack(alignment: .leading, spacing: Theme.gutter) {
            if let persistenceError = store.persistenceError {
                InlinePersistenceBanner(
                    message: persistenceError,
                    retry: store.retryPersistence,
                    reveal: { NSWorkspace.shared.open(store.persistenceLocation) })
            }
            CommandPreview(recipe: draft, command: command)
            launchActions
            Divider()
            savedRecipes
        }
    }

    private var launchActions: some View {
        VStack(alignment: .leading, spacing: 8) {
            LaunchVerb(enabled: !draft.cwd.isEmpty, action: launch)
            HStack(spacing: 8) {
                QuietTapButton(action: {
                    save()
                }) {
                    Label(editingID == nil ? "Save recipe" : "Update recipe", systemImage: "square.and.arrow.down")
                        .frame(maxWidth: .infinity)
                }
                .disabled(draft.name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            Text("The composed command is copied to your clipboard — paste it into any terminal to start the session. Skills are a prompt hint — they resolve at runtime via /skill-name.")
                .font(.caption2).foregroundStyle(Theme.muted)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var savedRecipes: some View {
        VStack(alignment: .leading, spacing: Theme.sectionGap) {
            HStack {
                SectionLabel("Saved recipes")
                Text("\(store.recipes.count)").font(.footnote).foregroundStyle(Theme.muted)
                Spacer()
                Text(RecipeRepository.defaultDirectory.path
                        .replacingOccurrences(of: NSHomeDirectory(), with: "~"))
                    .font(.caption2).foregroundStyle(Theme.faint)
                    .lineLimit(1).truncationMode(.middle)
            }
            if store.recipes.isEmpty {
                Text("No recipes yet. Compose one above and Save — recipes are plain JSON in ~/Library/Application Support/Trifola/recipes.")
                    .font(.caption).foregroundStyle(Theme.muted)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                ForEach(store.recipes) { r in
                    RecipeCardView(recipe: r,
                                   onLaunch: { launchSaved(r) },
                                   onEdit: { draft = r; editingID = r.id; flash("Editing “\(r.name)”") },
                                   onDuplicate: {
                                       if let copy = store.duplicate(r) {
                                           draft = copy
                                           editingID = copy.id
                                       }
                                   },
                                   onDelete: { store.delete(r.id) })
                }
            }
        }
        .task { store.reload() }
    }

    // MARK: Actions

    private func launch() {
        let cmd = store.compose(draft)
        store.copyToClipboard(cmd.shellCommand)
        flash(store.persistenceError == nil ? "Command copied" : "Command copied without skill hint")
    }

    private func launchSaved(_ r: Recipe) {
        let cmd = store.compose(r)
        store.copyToClipboard(cmd.shellCommand)
        flash(store.persistenceError == nil ? "Command copied" : "Command copied without skill hint")
    }

    private func save() {
        var r = draft
        let isNew = editingID == nil
        if isNew { r.createdAt = Date() }
        guard let saved = store.save(r) else { return }
        draft = saved
        editingID = saved.id
        flash(isNew ? "Recipe saved" : "Recipe updated")
    }

    private func flash(_ text: String) {
        feedback = text
        Task { try? await Task.sleep(for: .seconds(2.5)); feedback = nil }
    }

    private func chooseDir(_ done: @escaping (String) -> Void) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url { done(url.path) }
    }
}

// MARK: - The screen's ONE prominent verb (POLISH C9 / UI_GRIND LNC-1)
// "The product is judgment plus a launch button" — so the button sits directly
// under the composed command, in-frame, always. Shared by the live screen and
// `--render-launch` so the render can never lose the screen's verb again.

struct LaunchVerb: View {
    var enabled = true
    var action: () -> Void = {}
    var body: some View {
        ProminentTapButton(size: .large, action: action) {
            Label("Copy launch command", systemImage: "paperplane.fill")
                .frame(maxWidth: .infinity)
        }
        .disabled(!enabled)
    }
}

// MARK: - Command preview (pure — reused by --render-launch)
// The composed command, shown before launch (no black box). Real flags vs. the
// skills prompt-hint are labeled honestly.

struct CommandPreview: View {
    let recipe: Recipe
    let command: RecipeCommand

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                SectionLabel("Composed command")
                Spacer()
            }
            // The recipe's own caution (W5): shown wherever the command is.
            if let w = recipe.warning, !w.isEmpty {
                HStack(spacing: Theme.rhythm) {
                    Image(systemName: "flame")
                        .font(.caption2.weight(.medium))
                        .foregroundStyle(Theme.amber)
                    Text(w).font(.caption2).foregroundStyle(Theme.muted)
                }
            }
            Text(command.shellCommand)
                .font(.system(.footnote, design: .monospaced))
                .foregroundStyle(Theme.ink)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .padding(Theme.codePadding)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background {
                    RoundedRectangle(cornerRadius: Theme.radiusRow, style: .continuous)
                        .fill(Theme.codeFill)
                }
            if !command.systemPromptText.isEmpty {
                DisclosureRow(label: "Skill hint (--append-system-prompt-file)",
                              detail: command.systemPromptText)
            }
        }
    }
}

private struct DisclosureRow: View {
    let label: String
    let detail: String
    @State private var open = false
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            TapButton(action: { open.toggle() }) {
                HStack(spacing: 4) {
                    Image(systemName: "chevron.right")
                        .font(.caption2.weight(.medium))
                        .disclosureChevron(isExpanded: open)
                    Text(label).font(.caption2)
                }
                .foregroundStyle(Theme.muted)
            }
            if open {
                Text(detail).font(.caption2).foregroundStyle(Theme.muted)
                    .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                    .motionRowTransition()
            }
        }
        .reorderMotion(value: open)
    }
}

// MARK: - Recipe card (pure — reused by --render-launch)

struct RecipeCardView: View {
    let recipe: Recipe
    var onLaunch: () -> Void = {}
    var onEdit: () -> Void = {}
    var onDuplicate: () -> Void = {}
    var onDelete: () -> Void = {}

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text(recipe.name).font(.subheadline.weight(.semibold)).foregroundStyle(Theme.ink).lineLimit(1)
                Spacer()
                // The card defers to the screen verb entirely (UI_GRIND LNC-2):
                // all four are bare glyphs; the send earns its hierarchy from
                // POSITION (leftmost), not from a filled tile.
                cardIcon("paperplane", "Launch", action: onLaunch)
                cardIcon("pencil", "Edit", action: onEdit)
                cardIcon("doc.on.doc", "Duplicate", action: onDuplicate)
                cardIcon("trash", "Delete", action: onDelete)
            }
            Text((recipe.cwd.isEmpty ? "no working dir" : recipe.cwd)
                    .replacingOccurrences(of: NSHomeDirectory(), with: "~"))
                .font(.caption2)
                .foregroundStyle(recipe.cwd.isEmpty ? Theme.muted : Theme.faint)
                .lineLimit(1).truncationMode(.middle)
            FlowLayout(spacing: 5, lineSpacing: 5) {
                MetaChip(icon: "gauge.with.dots.needle.67percent", text: recipe.effort.label)
                if recipe.permissionMode != .standard {
                    MetaChip(icon: "lock.shield", text: recipe.permissionMode.label)
                }
                // MAIN-loop model pin (W5) — tinted by tier so a deliberate
                // Custom pin reads as the explicit choice it is.
                if let m = recipe.model, !m.isEmpty {
                    MetaChip(icon: "cpu", text: m, tint: ModelTier(raw: m).color)
                }
                if recipe.prompt?.isEmpty == false {
                    MetaChip(icon: "text.alignleft", text: "opens with a brief")
                }
                ForEach(recipe.agents) { a in
                    MetaChip(icon: "person.fill", text: "\(a.name)·\(a.model.rawValue)",
                             tint: a.model.tier.color)
                }
                if !recipe.skillRefs.isEmpty {
                    MetaChip(icon: "puzzlepiece.extension", text: "\(recipe.skillRefs.count) skills")
                }
                if recipe.background { MetaChip(icon: "moon", text: "bg") }
                // The visible caution chip (W5 §3.4): the field-reported quota
                // burn rides the card, not the fine print.
                if let w = recipe.warning, !w.isEmpty {
                    MetaChip(icon: "flame", text: w, tint: Theme.amber)
                }
            }
        }
        .padding(Theme.cardPadding)
        .background {
            RoundedRectangle(cornerRadius: Theme.radiusCard, style: .continuous)
                .fill(Theme.cardFill)
            RoundedRectangle(cornerRadius: Theme.radiusCard, style: .continuous)
                .strokeBorder(Theme.cardStroke, lineWidth: 1)
        }
    }

    private func cardIcon(_ symbol: String, _ help: String, action: @escaping () -> Void) -> some View {
        TapButton(action: action) { Image(systemName: symbol).font(.caption.weight(.medium)) }
            .foregroundStyle(Theme.muted).frame(width: 20)
            .help(help)
            .accessibilityLabel(help)
            .accessibilityHint("Acts on this saved recipe")
    }
}

private struct MetaChip: View {
    let icon: String
    let text: String
    var tint: Color = Theme.muted
    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: icon).font(.system(size: 9, weight: .medium))
            Text(text).font(.caption2)
        }
        .foregroundStyle(tint)
        .padding(.horizontal, Theme.rhythm).padding(.vertical, Theme.micro / 2)
        .background {
            Capsule().fill(Theme.cardFill)
            Capsule().strokeBorder(Theme.cardStroke, lineWidth: 1)
        }
    }
}

// MARK: - Small builder controls

private struct LabeledField<Content: View>: View {
    let label: String
    @ViewBuilder let content: () -> Content
    init(_ label: String, @ViewBuilder content: @escaping () -> Content) {
        self.label = label; self.content = content
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label).font(.caption).foregroundStyle(Theme.muted)
            content()
                .padding(.horizontal, Theme.intraCell).padding(.vertical, Theme.rhythm)
                .background {
                    RoundedRectangle(cornerRadius: Theme.radiusRow, style: .continuous)
                        .fill(Theme.codeFill)
                    RoundedRectangle(cornerRadius: Theme.radiusRow, style: .continuous)
                        .strokeBorder(Theme.cardStroke, lineWidth: 1)
                }
        }
    }
}

private struct PathField: View {
    @Binding var path: String
    var placeholder: String
    var chooseFile: Bool
    var body: some View {
        HStack(spacing: 6) {
            TextField(placeholder, text: $path)
                .textFieldStyle(.plain).font(.subheadline).foregroundStyle(Theme.ink)
            QuietTapButton("Choose…") {
                let panel = NSOpenPanel()
                panel.canChooseFiles = chooseFile
                panel.canChooseDirectories = !chooseFile
                if panel.runModal() == .OK, let url = panel.url { path = url.path }
            }
        }
    }
}

private struct DirListEditor: View {
    let title: String
    @Binding var dirs: [String]
    @State private var pending = ""
    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title).font(.caption).foregroundStyle(Theme.muted)
            if !dirs.isEmpty {
                FlowLayout(spacing: 5, lineSpacing: 5) {
                    ForEach(Array(dirs.enumerated()), id: \.offset) { i, d in
                        HStack(spacing: 4) {
                            Text((d as NSString).lastPathComponent).font(.caption2).foregroundStyle(Theme.muted)
                            TapButton(action: { dirs.remove(at: i) }) { Image(systemName: "xmark").font(.system(size: 8, weight: .medium)) }
                                .foregroundStyle(Theme.faint)
                                .accessibilityLabel("Remove directory \((d as NSString).lastPathComponent)")
                                .accessibilityHint("Removes this directory from the recipe")
                        }
                        .padding(.horizontal, Theme.rhythm).padding(.vertical, Theme.micro / 2)
                        .background {
                            Capsule().fill(Theme.cardFill)
                            Capsule().strokeBorder(Theme.cardStroke, lineWidth: 1)
                        }
                    }
                }
            }
            HStack(spacing: 6) {
                TextField("add a dir…", text: $pending)
                    .textFieldStyle(.plain).font(.caption).foregroundStyle(Theme.ink)
                    .onSubmit(add)
                QuietTapButton("Add", action: add)
                    .disabled(pending.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            .padding(.horizontal, Theme.intraCell).padding(.vertical, Theme.rowVerticalInset)
            .background {
                RoundedRectangle(cornerRadius: Theme.radiusRow, style: .continuous).fill(Theme.codeFill)
                RoundedRectangle(cornerRadius: Theme.radiusRow, style: .continuous).strokeBorder(Theme.cardStroke, lineWidth: 1)
            }
        }
    }
    private func add() {
        let t = pending.trimmingCharacters(in: .whitespaces)
        guard !t.isEmpty else { return }
        dirs.append((t as NSString).expandingTildeInPath); pending = ""
    }
}

// MARK: Agents editor (doctrine: default pin = Opus)

private struct AgentsEditor: View {
    @Binding var agents: [RecipeAgent]

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.sectionGap) {
            HStack {
                SectionLabel("Agents (--agents)")
                Spacer()
                QuietTapButton(action: {
                    agents.append(RecipeAgent(name: "agent\(agents.count + 1)",
                                              description: "", prompt: ""))
                }) { Label("Add agent", systemImage: "plus") }
            }
            Text("Each agent pins a model at composition time, so a subagent never silently inherits the main-loop model.")
                .font(.caption2).foregroundStyle(Theme.muted).fixedSize(horizontal: false, vertical: true)
            if agents.isEmpty {
                Text("No custom agents — the session runs with your defaults.")
                    .font(.caption).foregroundStyle(Theme.muted)
            } else {
                ForEach($agents) { $agent in
                    AgentRow(agent: $agent) {
                        agents.removeAll { $0.id == agent.id }
                    }
                }
            }
        }
    }
}

private struct AgentRow: View {
    @Binding var agent: RecipeAgent
    let onRemove: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                TextField("name", text: $agent.name)
                    .textFieldStyle(.plain).font(.subheadline.weight(.medium)).foregroundStyle(Theme.ink)
                    .frame(width: 140)
                Picker("", selection: $agent.model) {
                    ForEach(AgentModel.allCases, id: \.self) { m in
                        Text(m.rawValue).tag(m)
                    }
                }
                .labelsHidden().frame(width: 110)
                Spacer()
                TapButton(action: { onRemove() }) { Image(systemName: "trash").font(.caption.weight(.medium)) }
                    .foregroundStyle(Theme.faint)
                    .accessibilityLabel("Remove agent \(agent.name)")
                    .accessibilityHint("Removes this agent from the recipe")
            }
            TextField("description", text: $agent.description)
                .textFieldStyle(.plain).font(.caption).foregroundStyle(Theme.muted)
            TextField("system prompt", text: $agent.prompt, axis: .vertical)
                .textFieldStyle(.plain).font(.caption).foregroundStyle(Theme.muted).lineLimit(1...4)
        }
        .padding(Theme.cardPadding)
        .background {
            RoundedRectangle(cornerRadius: Theme.radiusCard, style: .continuous).fill(Theme.cardFill)
            RoundedRectangle(cornerRadius: Theme.radiusCard, style: .continuous).strokeBorder(Theme.cardStroke, lineWidth: 1)
        }
    }
}

// MARK: Skills editor (a prompt HINT, not an install)

private struct SkillsEditor: View {
    @Binding var draft: Recipe
    let catalog: [Skill]
    @State private var query = ""

    private var suggestions: [Skill] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return [] }
        return catalog
            .filter { !draft.skillRefs.contains($0.id) &&
                      ($0.id.lowercased().contains(q) || $0.name.lowercased().contains(q)) }
            .prefix(6).map { $0 }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.sectionGap) {
            SectionLabel("Skills")
            Text("Skills resolve at RUNTIME via /skill-name — this is a system-prompt hint (“lead with X”), not an install. Honest by design. ★ = lead skill, named first in the prompt hint.")
                .font(.caption2).foregroundStyle(Theme.muted).fixedSize(horizontal: false, vertical: true)

            if !draft.skillRefs.isEmpty {
                FlowLayout(spacing: 5, lineSpacing: 5) {
                    ForEach(draft.skillRefs, id: \.self) { ref in
                        SkillRefChip(ref: ref, isLead: draft.resolvedLeadSkill == ref,
                                     onLead: { draft.leadSkill = ref },
                                     onRemove: {
                                        draft.skillRefs.removeAll { $0 == ref }
                                        if draft.leadSkill == ref { draft.leadSkill = draft.skillRefs.first }
                                     })
                    }
                }
            }
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass").font(.caption.weight(.medium)).foregroundStyle(Theme.muted)
                    TextField("add a skill by name…", text: $query)
                        .textFieldStyle(.plain).font(.subheadline).foregroundStyle(Theme.ink)
                        .onSubmit { if let s = suggestions.first { addRef(s.id) } }
                }
                .padding(.horizontal, Theme.intraCell).padding(.vertical, Theme.rhythm)
                ForEach(suggestions) { s in
                    TapButton(action: { addRef(s.id) }) {
                        HStack(spacing: 6) {
                            Text(s.name).font(.caption).foregroundStyle(Theme.ink)
                            Text(s.source.lane.title).font(.caption2).foregroundStyle(Theme.faint)
                            Spacer()
                            Image(systemName: "plus").font(.caption2.weight(.medium)).foregroundStyle(Theme.muted)
                        }
                        .padding(.horizontal, Theme.intraCell).padding(.vertical, Theme.micro).contentShape(Rectangle())
                    }
                }
            }
            .background {
                RoundedRectangle(cornerRadius: Theme.radiusRow, style: .continuous).fill(Theme.codeFill)
                RoundedRectangle(cornerRadius: Theme.radiusRow, style: .continuous).strokeBorder(Theme.cardStroke, lineWidth: 1)
            }
        }
    }

    private func addRef(_ id: String) {
        if !draft.skillRefs.contains(id) { draft.skillRefs.append(id) }
        if draft.leadSkill == nil { draft.leadSkill = id }
        query = ""
    }
}

struct SkillRefChip: View {
    let ref: String
    let isLead: Bool
    var onLead: () -> Void = {}
    var onRemove: () -> Void = {}
    var body: some View {
        HStack(spacing: 4) {
            TapButton(action: onLead) {
                Image(systemName: isLead ? "star.fill" : "star")
                    .font(.system(size: 9, weight: .medium)).foregroundStyle(isLead ? Theme.ink : Theme.faint)
            }
            .help(isLead ? "Lead skill" : "Make lead skill")
            .accessibilityLabel(isLead ? "Lead skill \(ref)" : "Make \(ref) the lead skill")
            .accessibilityHint("The lead skill is named first in the prompt hint")
            Text("/\(ref)").font(.caption2).foregroundStyle(Theme.ink)
            TapButton(action: onRemove) { Image(systemName: "xmark").font(.system(size: 8, weight: .medium)) }
                .foregroundStyle(Theme.faint)
                .accessibilityLabel("Remove skill \(ref)")
                .accessibilityHint("Removes this skill from the recipe")
        }
        .padding(.horizontal, Theme.toastVerticalInset).padding(.vertical, Theme.rhythm / 2)
        .background(Capsule().fill(isLead ? Theme.selectionBG : Theme.cardFill))
        .overlay(Capsule().strokeBorder(Theme.cardStroke, lineWidth: 1))
    }
}
