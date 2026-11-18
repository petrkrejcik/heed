import Foundation

/// In-memory note content for the fixtures world. Used by `NoteTabView` / `NoteSurfaces` and `NoteIndex` fixture
/// scanning.
extension Fixtures {
    /// The vault root for fixtures.
    static let vault = "\(home)/notes"

    /// In-memory markdown content keyed by absolute path. Covers the tasks' note paths and an extra epic note.
    public static let noteContents: [String: String] = [
        "\(notes)/Fix image upload 403.md": fixImageUploadNote,
        "\(notes)/Chat attachments.md": chatAttachmentsEpicNote,
        "\(notes)/Kibana main.md": kibanaMainNote,
    ]

    /// The note index built from in-memory fixture notes (no filesystem scan).
    public static let noteEntries: [NoteEntry] = noteContents.keys.compactMap { path -> NoteEntry? in
        let content = noteContents[path] ?? ""
        let url = URL(fileURLWithPath: path)
        let name = url.deletingPathExtension().lastPathComponent
        let vaultPrefix = vault.hasSuffix("/") ? vault : vault + "/"
        guard path.hasPrefix(vaultPrefix) else { return nil }
        let relativeWithExt = String(path.dropFirst(vaultPrefix.count))
        let relative = (relativeWithExt as NSString).deletingPathExtension as String
        let folder = (relative as NSString).deletingLastPathComponent as String
        let aliases = NoteIndex.extractAliases(from: content)
        return NoteEntry(
            path: path, name: name, relativePath: relative,
            aliases: aliases, folder: folder, modifiedAt: .distantPast
        )
    }

    // MARK: Note text

    static let fixImageUploadNote = """
    ---
    type: task
    task_id: 3f1c9a2e-7b4d-4e8a-9c61-5d2f0b8e4a17
    status: In Progress
    epic: "[[Chat attachments]]"
    tags: [kibana, bug]
    ---

    # Fix image upload 403

    > [!note] Maintaining this note
    > Upload goes through the Kibana base path with the XSRF header. Epic: [[Chat attachments|the epic]].

    ## Problem

    Uploading an image in the chat fails with **403** when Kibana runs behind a reverse proxy.
    The fix sends uploads through `kbnFetch` instead of raw `fetch`. Not [[Archived plan]] any more.

    ## Plan

    - [x] Add `credentials: 'same-origin'` to the fetch call
    - [x] Pass the XSRF header via `kbnFetch`
    - [ ] Add a test for uploads behind a proxy

    > [!warning]- Proxy setups we don't test
    > Path rewriting proxies that drop custom headers.

    ```mermaid
    flowchart LR
      Chat --> kbnFetch --> Proxy --> Kibana
    ```

    ![[Kibana main]]

    ## Code

    ```typescript
    export const uploadImage = async (http: HttpSetup, file: File) => {
      const form = new FormData();
      form.append('file', file);
      return http.post<UploadedImage>('/api/chat/upload', { body: form });
    };
    ```

    ==Highlight:== this approach avoids the proxy stripping cookies.

    %% This is an Obsidian comment and should be hidden. %%

    #bug #kibana
    """

    static let chatAttachmentsEpicNote = """
    ---
    type: epic
    status: In Progress
    aliases:
      - Chat Attachments
    tags: [kibana, epic]
    ---

    # Chat attachments

    Epic covering file attachment support in the Kibana AI chat.

    ## Tasks

    - [[Fix image upload 403]]
    - Attachment size limits
    - Virus scanning

    ## Notes

    The backend stores attachments in Elasticsearch as base64 blobs for now.

    ```yaml
    index: .kibana-attachments
    shards: 1
    ```
    """

    static let kibanaMainNote = """
    ---
    type: task
    status: In Progress
    tags: [kibana]
    ---

    # Kibana main

    Main Kibana checkout used for exploration and reviews.

    ## Quick links

    - [Kibana repo](https://github.com/elastic/kibana)
    - [[Fix image upload 403]]

    ## Checklist

    - [x] yarn kbn bootstrap
    - [x] yarn start
    - [ ] Run tests
    """

    /// Returns the in-memory content of `path`; nil when the fixture does not include it.
    public static func noteContent(at path: String) -> String? { noteContents[path] }
}
