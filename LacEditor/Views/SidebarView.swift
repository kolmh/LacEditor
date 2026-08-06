import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct SidebarView: View {
    @EnvironmentObject private var appState: AppState
    @EnvironmentObject private var windowManager: WindowManager
    @Environment(\.openSettings) private var openSettings
    @Environment(\.colorScheme) private var colorScheme
    @State private var isSettingsHovering = false

    var body: some View {
        VStack(spacing: 0) {
            SidebarLibraryView(
                recentFiles: appState.recentFiles,
                library: windowManager.sidebarLibrary
            )

            Divider()
                .opacity(0.45)

            Button {
                openSettings()
            } label: {
                Label("设置", systemImage: "gearshape")
                    .font(.system(size: 12))
                    .foregroundStyle(isSettingsHovering ? .primary : .secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 8)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .stableHelp("打开设置", shortcut: "⌘,")
            .frame(height: 35)
            .background(
                isSettingsHovering ? Color.primary.opacity(0.05) : .clear,
                in: RoundedRectangle(cornerRadius: 5, style: .continuous)
            )
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .onHover { isSettingsHovering = $0 }
        }
        .background {
            ZStack {
                LacSidebarMaterial()
                Color(nsColor: .lacEditorBackground)
                    .opacity(colorScheme == .dark ? 0.12 : 0.22)
            }
            .ignoresSafeArea()
        }
        .overlay(alignment: .trailing) {
            Rectangle()
                .fill(
                    Color(nsColor: .separatorColor)
                        .opacity(colorScheme == .dark ? 0.58 : 0.46)
                )
                .frame(width: 1)
                .ignoresSafeArea(.container, edges: .vertical)
                .allowsHitTesting(false)
        }
    }
}

private struct SidebarLibraryView: View {
    @EnvironmentObject private var appState: AppState
    @EnvironmentObject private var windowManager: WindowManager
    @ObservedObject var recentFiles: RecentFilesStore
    @ObservedObject var library: SidebarLibraryStore
    @State private var hoveredSection: SidebarLibrarySection?

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                Text("文件")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                Button {
                    windowManager.requestCreateSidebarGroup()
                } label: {
                    Image(systemName: "folder.badge.plus")
                        .font(.system(size: 11))
                        .frame(width: 24, height: 24)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .stableHelp("新建分组")
            }
            .padding(.leading, 13)
            .padding(.trailing, 9)
            .frame(height: 36)

            ScrollView {
                LazyVStack(spacing: 10) {
                    sidebarSection(
                        title: "收藏夹",
                        icon: "star.fill",
                        section: .favorites,
                        count: library.favoriteURLs.count
                    ) {
                        if library.favoriteURLs.isEmpty {
                            Text("可从文件右键菜单添加收藏")
                                .font(.system(size: 10))
                                .foregroundStyle(.tertiary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.leading, 30)
                                .frame(height: 25)
                        } else {
                            fileList(
                                urls: library.favoriteURLs,
                                location: .favorites
                            )
                        }
                    }

                    sidebarSection(
                        title: "分组",
                        icon: "folder",
                        section: .groups,
                        count: library.groups.count
                    ) {
                        if library.groups.isEmpty {
                            Button("新建分组") {
                                windowManager.requestCreateSidebarGroup()
                            }
                            .buttonStyle(.plain)
                            .font(.system(size: 11))
                            .foregroundStyle(.tertiary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.leading, 30)
                            .frame(height: 26)
                        } else {
                            ForEach(library.groups) { group in
                                SidebarGroupView(group: group, library: library)
                            }
                            Color.clear
                                .frame(height: 5)
                                .onDrop(
                                    of: SidebarDragPayload.supportedTypes,
                                    delegate: SidebarGroupDropDelegate(
                                        targetGroupID: nil,
                                        library: library
                                    )
                                )
                        }
                    }

                    sidebarSection(
                        title: "最近文件",
                        icon: "clock",
                        section: .recent,
                        count: recentFiles.urls.count
                    ) {
                        if recentFiles.urls.isEmpty {
                            VStack(spacing: 7) {
                                Text("暂无最近文件")
                                    .font(.system(size: 11))
                                    .foregroundStyle(.tertiary)
                                Button("打开文件…") {
                                    appState.openFiles()
                                }
                                .controlSize(.small)
                            }
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 12)
                        } else {
                            fileList(urls: recentFiles.urls, location: .recent)
                        }
                    }
                }
                .padding(.horizontal, 6)
                .padding(.bottom, 8)
            }
        }
    }

    @ViewBuilder
    private func sidebarSection<Content: View>(
        title: String,
        icon: String,
        section: SidebarLibrarySection,
        count: Int,
        @ViewBuilder content: @escaping () -> Content
    ) -> some View {
        let isExpanded = library.isExpanded(section)
        let isHovering = hoveredSection == section
        VStack(spacing: 2) {
            HStack(spacing: 6) {
                Button {
                    withAnimation(.easeInOut(duration: 0.14)) {
                        library.setExpanded(!isExpanded, for: section)
                    }
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: icon)
                            .font(.system(size: 10))
                            .frame(width: 13)
                        Text(title)
                            .font(.system(size: 11, weight: .semibold))
                        if count > 0 {
                            Text("\(count)")
                                .font(.system(size: 9, weight: .medium))
                                .foregroundStyle(.tertiary)
                                .monospacedDigit()
                        }
                        Image(systemName: "chevron.right")
                            .font(.system(size: 8, weight: .semibold))
                            .rotationEffect(.degrees(isExpanded ? 90 : 0))
                            .opacity(isHovering ? 1 : 0)
                            .animation(.easeOut(duration: 0.1), value: isHovering)
                            .frame(width: 9)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .onHover { hovering in
                    hoveredSection = hovering ? section : nil
                }
                Spacer()
                if section == .recent, !recentFiles.urls.isEmpty, isExpanded {
                    Button {
                        windowManager.requestClearRecentFiles()
                    } label: {
                        Image(systemName: "trash")
                            .font(.system(size: 10))
                            .frame(width: 20, height: 20)
                    }
                    .buttonStyle(.plain)
                    .stableHelp("清除最近文件")
                }
            }
            .foregroundStyle(.secondary)
            .padding(.horizontal, 7)
            .frame(height: 25)

            if isExpanded {
                content()
                    .transition(.sidebarVerticalReveal)
            }
        }
        .clipped()
    }

    @ViewBuilder
    private func fileList(
        urls: [URL],
        location: SidebarFileLocation
    ) -> some View {
        VStack(spacing: 2) {
            ForEach(urls, id: \.path) { url in
                SidebarFileRow(url: url, location: location)
                    .onDrag {
                        SidebarDragPayload.file(url, location: location).itemProvider()
                    }
                    .onDrop(
                        of: SidebarDragPayload.supportedTypes,
                        delegate: SidebarFileDropDelegate(
                            targetURL: url,
                            targetLocation: location,
                            library: library
                        )
                    )
            }

            Color.clear
                .frame(height: 5)
                .onDrop(
                    of: SidebarDragPayload.supportedTypes,
                    delegate: SidebarFileDropDelegate(
                        targetURL: nil,
                        targetLocation: location,
                        library: library
                    )
                )
        }
    }
}

private struct SidebarGroupView: View {
    @EnvironmentObject private var windowManager: WindowManager
    let group: SidebarFileGroup
    @ObservedObject var library: SidebarLibraryStore
    @State private var isHovering = false

    var body: some View {
        VStack(spacing: 2) {
            Button {
                withAnimation(.easeInOut(duration: 0.16)) {
                    library.setExpanded(!group.isExpanded, for: group.id)
                }
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: group.isExpanded ? "folder.fill" : "folder")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .frame(width: 15)
                        .contentTransition(.symbolEffect(.replace))
                    Text(group.name)
                        .font(.system(size: 12, weight: .medium))
                        .lineLimit(1)
                    Spacer()
                    if !group.paths.isEmpty {
                        Text("\(group.paths.count)")
                            .font(.system(size: 10))
                            .foregroundStyle(.tertiary)
                            .monospacedDigit()
                    }
                }
                .padding(.horizontal, 6)
                .frame(height: 28)
                .contentShape(Rectangle())
                .background(
                    isHovering ? Color.primary.opacity(0.05) : .clear,
                    in: RoundedRectangle(cornerRadius: 5, style: .continuous)
                )
            }
            .buttonStyle(.plain)
            .onHover { isHovering = $0 }
            .onDrag { SidebarDragPayload.group(group.id).itemProvider() }
            .onDrop(
                of: SidebarDragPayload.supportedTypes,
                delegate: SidebarGroupDropDelegate(
                    targetGroupID: group.id,
                    library: library
                )
            )
            .contextMenu {
                Button {
                    windowManager.requestRenameSidebarGroup(group)
                } label: {
                    Label("重命名分组…", systemImage: "pencil")
                }
                Button(role: .destructive) {
                    windowManager.requestDeleteSidebarGroup(group)
                } label: {
                    Label("删除分组", systemImage: "trash")
                }
            }

            if group.isExpanded {
                VStack(spacing: 2) {
                    ForEach(group.urls, id: \.path) { url in
                        SidebarFileRow(url: url, location: .group(group.id))
                            .padding(.leading, 15)
                            .onDrag {
                                SidebarDragPayload.file(
                                    url,
                                    location: .group(group.id)
                                ).itemProvider()
                            }
                            .onDrop(
                                of: SidebarDragPayload.supportedTypes,
                                delegate: SidebarFileDropDelegate(
                                    targetURL: url,
                                    targetLocation: .group(group.id),
                                    library: library
                                )
                            )
                    }

                    Color.clear
                        .frame(height: 4)
                        .onDrop(
                            of: SidebarDragPayload.supportedTypes,
                            delegate: SidebarFileDropDelegate(
                                targetURL: nil,
                                targetLocation: .group(group.id),
                                library: library
                            )
                        )
                }
                .transition(.sidebarVerticalReveal)
            }
        }
        .clipped()
        .animation(.easeInOut(duration: 0.16), value: group.isExpanded)
    }
}

private struct SidebarVerticalRevealModifier: ViewModifier, Animatable {
    var progress: CGFloat

    var animatableData: CGFloat {
        get { progress }
        set { progress = newValue }
    }

    func body(content: Content) -> some View {
        content.mask(alignment: .top) {
            GeometryReader { proxy in
                Rectangle()
                    .frame(
                        width: proxy.size.width,
                        height: max(0, proxy.size.height * progress),
                        alignment: .top
                    )
            }
        }
    }
}

private extension AnyTransition {
    static var sidebarVerticalReveal: AnyTransition {
        .modifier(
            active: SidebarVerticalRevealModifier(progress: 0),
            identity: SidebarVerticalRevealModifier(progress: 1)
        )
    }
}

private enum SidebarFileLocation: Equatable {
    case favorites
    case group(UUID)
    case recent
}

private struct SidebarFileRow: View {
    @EnvironmentObject private var appState: AppState
    @EnvironmentObject private var windowManager: WindowManager
    let url: URL
    let location: SidebarFileLocation
    @State private var isHovering = false

    private var exists: Bool {
        FileManager.default.fileExists(atPath: url.path)
    }

    private var isOpen: Bool {
        appState.documents.contains {
            $0.fileIdentity?.matches(DocumentFileIdentity.resolve(url)) == true
        }
    }

    var body: some View {
        Button {
            if exists {
                appState.openFile(url)
            } else {
                windowManager.requestRelocateSidebarFile(url)
            }
        } label: {
            HStack(spacing: 7) {
                Capsule()
                    .fill(isOpen ? Color.accentColor : .clear)
                    .frame(width: 2, height: 17)

                Image(systemName: exists
                      ? EditorLanguage.infer(from: url).icon
                      : "exclamationmark.triangle")
                    .font(.system(size: 11))
                    .foregroundStyle(
                        exists
                            ? (isOpen ? Color.accentColor : Color.secondary)
                            : Color.orange
                    )
                    .frame(width: 16)

                VStack(alignment: .leading, spacing: 1) {
                    Text(url.lastPathComponent)
                        .font(.system(size: 12, weight: isOpen ? .medium : .regular))
                        .lineLimit(1)
                    Text(exists
                         ? url.deletingLastPathComponent().lastPathComponent
                         : "文件已移动或删除")
                        .font(.system(size: 10))
                        .foregroundStyle(exists ? .tertiary : .secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            .opacity(exists ? 1 : 0.65)
            .padding(.horizontal, 6)
            .frame(height: LacEditorDesign.sidebarRowHeight)
            .contentShape(Rectangle())
            .background(
                isHovering ? Color.primary.opacity(0.05) : .clear,
                in: RoundedRectangle(
                    cornerRadius: LacEditorDesign.compactCornerRadius,
                    style: .continuous
                )
            )
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .contextMenu { contextMenu }
    }

    @ViewBuilder
    private var contextMenu: some View {
        if exists {
            Button {
                appState.openFile(url)
            } label: {
                Label("打开", systemImage: "doc.text")
            }
            Button {
                windowManager.openFileInNewWindow(url)
            } label: {
                Label("用新窗口打开", systemImage: "macwindow.badge.plus")
            }

            Divider()

            Button {
                windowManager.sidebarLibrary.toggleFavorite(url)
            } label: {
                Label(
                    windowManager.sidebarLibrary.isFavorite(url)
                        ? "取消收藏"
                        : "添加到收藏夹",
                    systemImage: windowManager.sidebarLibrary.isFavorite(url)
                        ? "star.slash"
                        : "star"
                )
            }

            Menu {
                ForEach(windowManager.sidebarLibrary.groups) { group in
                    Button {
                        windowManager.sidebarLibrary.add(url, toGroup: group.id)
                    } label: {
                        Label(
                            group.name,
                            systemImage: windowManager.sidebarLibrary
                                .groupsContaining(url).contains(group.id)
                                ? "checkmark"
                                : "folder"
                        )
                    }
                }
                if !windowManager.sidebarLibrary.groups.isEmpty {
                    Divider()
                }
                Button {
                    windowManager.requestCreateSidebarGroup(adding: url)
                } label: {
                    Label("新建分组…", systemImage: "folder.badge.plus")
                }
            } label: {
                Label("添加到分组", systemImage: "folder")
            }

            Divider()

            Button {
                windowManager.requestRenameFile(url)
            } label: {
                Label("重命名…", systemImage: "pencil")
            }
            Button {
                NSWorkspace.shared.activateFileViewerSelecting([url])
            } label: {
                Label("在 Finder 中显示", systemImage: "folder")
            }
        } else {
            Button {
                windowManager.requestRelocateSidebarFile(url)
            } label: {
                Label("重新定位…", systemImage: "arrow.triangle.2.circlepath")
            }
        }

        Divider()

        switch location {
        case .favorites:
            Button(role: .destructive) {
                windowManager.sidebarLibrary.toggleFavorite(url)
            } label: {
                Label("从收藏夹移除", systemImage: "star.slash")
            }
        case let .group(id):
            Button(role: .destructive) {
                windowManager.sidebarLibrary.remove(url, fromGroup: id)
            } label: {
                Label("从分组中移除", systemImage: "minus.circle")
            }
        case .recent:
            Button(role: .destructive) {
                appState.recentFiles.remove(url)
            } label: {
                Label("从最近文件中删除", systemImage: "trash")
            }
        }
    }
}

private struct SidebarDragPayload: Codable {
    static let supportedTypes: [UTType] = [.utf8PlainText, .fileURL]
    enum Kind: String, Codable {
        case file
        case group
    }

    let kind: Kind
    let path: String?
    let groupID: UUID?
    let sourceGroupID: UUID?
    let isFavorite: Bool

    static func file(_ url: URL, location: SidebarFileLocation) -> Self {
        let groupID: UUID?
        let isFavorite: Bool
        switch location {
        case .favorites:
            groupID = nil
            isFavorite = true
        case let .group(id):
            groupID = id
            isFavorite = false
        case .recent:
            groupID = nil
            isFavorite = false
        }
        return Self(
            kind: .file,
            path: url.path,
            groupID: nil,
            sourceGroupID: groupID,
            isFavorite: isFavorite
        )
    }

    static func group(_ id: UUID) -> Self {
        Self(
            kind: .group,
            path: nil,
            groupID: id,
            sourceGroupID: nil,
            isFavorite: false
        )
    }

    func itemProvider() -> NSItemProvider {
        let data = try? JSONEncoder().encode(self)
        let string = data?.base64EncodedString() ?? ""
        return NSItemProvider(object: string as NSString)
    }

    static func load(from info: DropInfo, completion: @escaping (Self) -> Void) -> Bool {
        if let provider = info.itemProviders(for: [.utf8PlainText]).first {
            provider.loadObject(ofClass: NSString.self) { object, _ in
                guard let string = object as? String,
                      let data = Data(base64Encoded: string),
                      let payload = try? JSONDecoder().decode(Self.self, from: data) else {
                    return
                }
                DispatchQueue.main.async { completion(payload) }
            }
            return true
        }

        guard let provider = info.itemProviders(for: [.fileURL]).first else { return false }
        provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier) { item, _ in
            let url: URL?
            if let value = item as? URL {
                url = value
            } else if let value = item as? NSURL {
                url = value as URL
            } else if let data = item as? Data,
                      let value = String(data: data, encoding: .utf8) {
                url = URL(string: value.trimmingCharacters(in: .whitespacesAndNewlines))
            } else {
                url = nil
            }
            guard let url, isSupportedFile(url) else { return }
            DispatchQueue.main.async {
                completion(.file(url, location: .recent))
            }
        }
        return true
    }

    private static func isSupportedFile(_ url: URL) -> Bool {
        guard FileService.supportedExtensions.contains(
            url.pathExtension.lowercased()
        ) else { return false }
        let values = try? url.resourceValues(forKeys: [.isRegularFileKey])
        return values?.isRegularFile == true
    }
}

private struct SidebarFileDropDelegate: DropDelegate {
    let targetURL: URL?
    let targetLocation: SidebarFileLocation
    let library: SidebarLibraryStore

    func validateDrop(info: DropInfo) -> Bool {
        info.hasItemsConforming(to: SidebarDragPayload.supportedTypes)
    }

    func performDrop(info: DropInfo) -> Bool {
        SidebarDragPayload.load(from: info) { payload in
            guard payload.kind == .file,
                  let path = payload.path else { return }
            let url = URL(fileURLWithPath: path)
            switch targetLocation {
            case .favorites:
                if !library.isFavorite(url) { library.toggleFavorite(url) }
                library.moveFavorite(url, before: targetURL)
            case let .group(id):
                library.add(url, toGroup: id)
                library.moveFile(url, inGroup: id, before: targetURL)
            case .recent:
                break
            }
        }
    }
}

private struct SidebarGroupDropDelegate: DropDelegate {
    let targetGroupID: UUID?
    let library: SidebarLibraryStore

    func validateDrop(info: DropInfo) -> Bool {
        info.hasItemsConforming(to: SidebarDragPayload.supportedTypes)
    }

    func performDrop(info: DropInfo) -> Bool {
        SidebarDragPayload.load(from: info) { payload in
            switch payload.kind {
            case .group:
                if let id = payload.groupID, id != targetGroupID {
                    library.moveGroup(id, before: targetGroupID)
                }
            case .file:
                if let path = payload.path, let targetGroupID {
                    library.add(URL(fileURLWithPath: path), toGroup: targetGroupID)
                }
            }
        }
    }
}
