import Foundation

/// The fake world's checkout for the Files tab: a Kibana-shaped file list with the upload fix's changes marked, a
/// few files git ignores (one config file, whole build folders), every file's text and find in files over them, all
/// in memory. No git, no disk, no ripgrep.
public extension Fixtures {
    /// The upload fix's files (task t2), as `FileListing.full` would list its worktree.
    static let fileList: FileList = {
        let plugin = "x-pack/platform/plugins/shared/onechat"
        let tracked = [
            ".buildkite/pipelines/pull_request.yml", ".gitignore", ".nvmrc", "README.md", "package.json",
            "tsconfig.json", "config/kibana.yml", "config/node.options",
            "src/core/packages/http/browser/src/fetch.ts", "src/core/packages/http/browser/src/fetch.test.ts",
            "src/core/packages/http/browser/src/types.ts", "src/core/packages/http/browser/index.ts",
            "src/platform/packages/shared/kbn-i18n/src/core/i18n.ts",
            "x-pack/platform/plugins/shared/onechat/kibana.jsonc", "\(plugin)/jest.config.js",
            "\(plugin)/common/constants.ts", "\(plugin)/common/types.ts",
            "\(plugin)/public/application.tsx", "\(plugin)/public/plugin.ts",
            "\(plugin)/public/components/conversation.tsx", "\(plugin)/public/components/chat_input.tsx",
            "\(plugin)/public/components/upload_button.tsx",
            "\(plugin)/public/hooks/use_upload.ts", "\(plugin)/server/plugin.ts", "\(plugin)/server/routes/index.ts",
            "\(plugin)/server/routes/conversations.ts",
        ] + diff.filter { $0.status != .added }.map(\.path)
        let marks = Dictionary(uniqueKeysWithValues: diff.map { file -> (String, FileList.Mark) in
            switch file.status {
            case .added: (file.path, .untracked)
            case .deleted: (file.path, .deleted)
            case .renamed: (file.path, .renamed)
            case .modified: (file.path, .modified)
            }
        })
        let status = FileStatus(
            marks: marks,
            untracked: diff.filter { $0.status == .added }.map(\.path),
            ignored: [
                "config/kibana.dev.yml", ".es/", "data/", "\(plugin)/target/",
                "src/core/packages/http/browser/target/",
            ]
        )
        return FileListing.list(tracked: tracked, status: status, exclude: FileExclusion(), root: nil, reading: [])
    }()

    /// What a fixture file says: the upload fix's files as the diff has them, a few others written out, the rest a
    /// line naming them.
    static func fileText(_ path: String) -> FileContents.Side {
        if let sides = diffContents[path] { return sides.new.map { .text($0) } ?? .missing }
        if let text = fileTexts[path] { return .text(text) }
        guard fileList.contains(file: path) else { return .missing }
        return .text("// \(path)\n")
    }

    /// Find in files over the fixture's texts, as ripgrep would answer: literal, smart case.
    static func search(_ query: String) -> [SearchEvent] {
        guard !query.isEmpty else { return [] }
        let insensitive = query == query.lowercased()
        let needle = Array((insensitive ? query.lowercased() : query).utf8)
        var events: [SearchEvent] = []
        for path in fileList.files {
            guard !fileList.isIgnored(path), case let .text(text) = fileText(path) else { continue }
            for (offset, line) in text.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
                let bytes = Array((insensitive ? line.lowercased() : String(line)).utf8)
                var ranges: [Range<Int>] = []
                var at = 0
                while at + needle.count <= bytes.count {
                    if Array(bytes[at ..< at + needle.count]) == needle {
                        ranges.append(at ..< at + needle.count)
                        at += needle.count
                    } else {
                        at += 1
                    }
                }
                guard !ranges.isEmpty else { continue }
                events.append(.match(RipgrepParser.shown(
                    path: path, line: offset + 1, raw: String(line), ranges: ranges
                )))
            }
        }
        return events
    }

    private static let fileTexts: [String: String] = [
        "package.json": #"""
        {
          "name": "kibana",
          "description": "Your window into the Elastic Stack",
          "version": "9.3.0",
          "private": true,
          "license": "Elastic License 2.0 OR AGPL-3.0-only OR SSPL-1.0",
          "scripts": {
            "bootstrap": "node scripts/kbn bootstrap",
            "start": "node scripts/kibana --dev",
            "test:jest": "node scripts/jest",
            "lint": "node scripts/eslint"
          },
          "engines": {
            "node": "22.17.1",
            "yarn": "^1.22.19"
          }
        }

        """#,
        "config/kibana.dev.yml": #"""
        # Local settings for this worktree; git ignores this file.
        server.port: 5602
        server.basePath: /fix
        elasticsearch.hosts: ["http://localhost:9200"]
        xpack.onechat.enabled: true

        """#,
        "src/core/packages/http/browser/src/fetch.ts": #"""
        /*
         * Copyright Elasticsearch B.V. and/or licensed to Elasticsearch B.V. under one
         * or more contributor license agreements. Licensed under the "Elastic License
         * 2.0", the "GNU Affero General Public License v3.0 only", and the "Server Side
         * Public License v 1"; you may not use this file except in compliance with, at
         * your election, the "Elastic License 2.0", the "GNU Affero General Public
         * License v3.0 only", or the "Server Side Public License, v 1".
         */

        import type { HttpFetchOptions, HttpResponse } from './types';

        export class Fetch {
          constructor(private readonly params: { basePath: string }) {}

          /** Prepends the base path and sends the xsrf header, so requests work behind a proxy. */
          public async fetch<T>(path: string, options: HttpFetchOptions = {}): Promise<HttpResponse<T>> {
            const url = `${this.params.basePath}${path}`;
            const response = await window.fetch(url, {
              ...options,
              credentials: 'same-origin',
              headers: { 'kbn-xsrf': 'true', ...options.headers },
            });
            return { response, body: (await response.json()) as T };
          }
        }

        """#,
        "\(Fixtures.onechat)/public/hooks/use_upload.ts": #"""
        import { useCallback, useState } from 'react';
        import { useKibana } from '@kbn/kibana-react-plugin/public';
        import { uploadImage, type UploadedImage } from '../upload_image';

        export const useUpload = () => {
          const { http } = useKibana().services;
          const [uploading, setUploading] = useState(false);

          const upload = useCallback(
            async (file: File): Promise<UploadedImage> => {
              setUploading(true);
              try {
                return await uploadImage(http!, file);
              } finally {
                setUploading(false);
              }
            },
            [http]
          );

          return { upload, uploading };
        };

        """#,
    ]

    internal static let onechat = "x-pack/platform/plugins/shared/onechat"
}
