import Foundation

/// The fake world's diff (the upload fix, task t2): whole files on both sides, so the Diff tab's merge view has
/// unchanged regions to collapse, and the unified diff git printed for them (`git diff --cached -M`).
extension Fixtures {
    /// The old and new contents of each changed file, by path; nil where the file does not exist on that side.
    static let diffContents: [String: (old: String?, new: String?)] = [
        "x-pack/platform/plugins/shared/onechat/public/upload_image.ts": (
            #"""
            /*
             * Copyright Elasticsearch B.V. and/or licensed to Elasticsearch B.V. under one
             * or more contributor license agreements. Licensed under the Elastic License
             * 2.0; you may not use this file except in compliance with the Elastic License
             * 2.0.
             */

            import type { HttpSetup } from '@kbn/core/public';

            /** The largest image the chat accepts, in bytes. */
            export const MAX_IMAGE_SIZE = 5 * 1024 * 1024;

            export interface UploadedImage {
              id: string;
              url: string;
            }

            export const uploadImage = async (
              http: HttpSetup,
              file: File
            ) => {
              const url = '/api/chat/attachments';
              // the proxy strips cookies on cross-origin requests
              const response = await fetch(url, { method: 'POST', body: file });
              if (!response.ok) {
              }
              return (await response.json()) as UploadedImage;
            };

            export const isImage = (file: File): boolean => file.type.startsWith('image/');

            export const checkSize = (file: File): boolean => file.size <= MAX_IMAGE_SIZE;

            export const describeFile = (file: File): string => {
              const kilobytes = Math.round(file.size / 1024);
              return `${file.name} (${kilobytes} KB)`;
            };

            export const toDataUrl = (file: File): Promise<string> =>
              new Promise((resolve, reject) => {
                const reader = new FileReader();
                reader.onload = () => resolve(String(reader.result));
                reader.onerror = () => reject(reader.error);
                reader.readAsDataURL(file);
              });

            export const resizeImage = async (file: File, width: number): Promise<Blob> => {
              const bitmap = await createImageBitmap(file);
              const scale = width / bitmap.width;
              const canvas = new OffscreenCanvas(width, Math.round(bitmap.height * scale));
              const context = canvas.getContext('2d');
              context?.drawImage(bitmap, 0, 0, canvas.width, canvas.height);
              return canvas.convertToBlob({ type: 'image/png' });
            };

            export const imageExtensions = ['png', 'jpg', 'jpeg', 'gif', 'webp'];

            export const hasImageExtension = (name: string): boolean =>
              imageExtensions.some((extension) => name.toLowerCase().endsWith(`.${extension}`));

            export class UploadError extends Error {
            }

            """#,
            #"""
            /*
             * Copyright Elasticsearch B.V. and/or licensed to Elasticsearch B.V. under one
             * or more contributor license agreements. Licensed under the Elastic License
             * 2.0; you may not use this file except in compliance with the Elastic License
             * 2.0.
             */

            import type { HttpSetup } from '@kbn/core/public';

            /** The largest image the chat accepts, in bytes. */
            export const MAX_IMAGE_SIZE = 5 * 1024 * 1024;

            export interface UploadedImage {
              id: string;
              url: string;
            }

            export const uploadImage = async (
              http: HttpSetup,
              file: File
            ) => {
              const url = http.basePath.prepend('/api/chat/attachments');
              const headers = { 'kbn-xsrf': 'true' };
              // the proxy strips cookies on cross-origin requests
              const response = await fetch(url, { method: 'POST', body: file, headers, credentials: 'same-origin' });
              if (!response.ok) {
                throw new UploadError(response.status);
              }
              return (await response.json()) as UploadedImage;
            };

            export const isImage = (file: File): boolean => file.type.startsWith('image/');

            export const checkSize = (file: File): boolean => file.size <= MAX_IMAGE_SIZE;

            export const describeFile = (file: File): string => {
              const kilobytes = Math.round(file.size / 1024);
              return `${file.name} (${kilobytes} KB)`;
            };

            export const toDataUrl = (file: File): Promise<string> =>
              new Promise((resolve, reject) => {
                const reader = new FileReader();
                reader.onload = () => resolve(String(reader.result));
                reader.onerror = () => reject(reader.error);
                reader.readAsDataURL(file);
              });

            export const resizeImage = async (file: File, width: number): Promise<Blob> => {
              const bitmap = await createImageBitmap(file);
              const scale = width / bitmap.width;
              const canvas = new OffscreenCanvas(width, Math.round(bitmap.height * scale));
              const context = canvas.getContext('2d');
              context?.drawImage(bitmap, 0, 0, canvas.width, canvas.height);
              return canvas.convertToBlob({ type: 'image/png' });
            };

            export const imageExtensions = ['png', 'jpg', 'jpeg', 'gif', 'webp'];

            export const hasImageExtension = (name: string): boolean =>
              imageExtensions.some((extension) => name.toLowerCase().endsWith(`.${extension}`));

            export class UploadError extends Error {
              constructor(public readonly status: number) {
                super(`upload failed: ${status}`);
              }
            }

            """#
        ),
        "x-pack/platform/plugins/shared/onechat/public/upload_image.test.ts": (
            nil,
            #"""
            import { uploadImage } from './upload_image';

            describe('uploadImage', () => {
              it('prepends the base path', async () => {
                const http = { basePath: { prepend: (path: string) => `/base${path}` } };
                global.fetch = jest.fn().mockResolvedValue({ ok: true, json: async () => ({ id: '1', url: '/a' }) });
                await uploadImage(http as never, new File([''], 'a.png'));
                expect(global.fetch).toHaveBeenCalledWith('/base/api/chat/attachments', expect.anything());
              });
            });

            """#
        ),
        "x-pack/platform/plugins/shared/onechat/README.md": (
            #"""
            # Onechat

            The chat's plugin: conversations, tools and attachments.

            ## Attachments

            Attachments go through the Kibana base path.
            A very long line that the linter rejects because it goes on and on.

            """#,
            #"""
            # Onechat

            The chat's plugin: conversations, tools and attachments.

            ## Attachments

            Attachments go through the Kibana base path.
            A shorter line.
            Images over 5 MB are refused before upload.

            """#
        ),
        "x-pack/platform/plugins/shared/onechat/server/routes/attachments.ts": (
            #"""
            import { schema } from '@kbn/config-schema';
            import type { IRouter } from '@kbn/core/server';

            export const registerAttachmentRoutes = (router: IRouter) => {
              router.post(
                {
                  path: '/api/chat/attachments',
                  validate: { body: schema.any() },
                  options: { body: { maxBytes: 5 * 1024 * 1024 } },
                },
                async (context, request, response) => {
                  const id = crypto.randomUUID();
                  return response.ok({ body: { id, url: `/api/chat/attachments/${id}` } });
                }
              );
            };

            """#,
            #"""
            import { schema } from '@kbn/config-schema';
            import type { IRouter } from '@kbn/core/server';

            export const registerAttachmentRoutes = (router: IRouter) => {
              router.post(
                {
                  path: '/api/chat/attachments',
                  validate: { body: schema.any() },
                  options: { body: { maxBytes: 5 * 1024 * 1024, accepts: ['image/*'] }, xsrfRequired: true },
                },
                async (context, request, response) => {
                  const id = crypto.randomUUID();
                  return response.ok({ body: { id, url: `/api/chat/attachments/${id}` } });
                }
              );
            };

            """#
        ),
        "x-pack/platform/plugins/shared/onechat/public/components/upload_button.scss": (
            #"""
            .onechatUploadButton {
              display: inline-flex;
              gap: 4px;

              &__icon {
                color: $euiColorMediumShade;
              }
            }

            """#,
            #"""
            .onechatUploadButton {
              display: inline-flex;
              gap: 8px;

              &__icon {
                color: $euiColorPrimary;
              }

              &--disabled {
                opacity: 0.5;
              }
            }

            """#
        ),
        "x-pack/platform/plugins/shared/onechat/tsconfig.json": (
            #"""
            {
              "extends": "../../../../../tsconfig.base.json",
              "compilerOptions": { "outDir": "target/types" },
              "include": ["public/**/*", "server/**/*"],
              "kbn_references": ["@kbn/core", "@kbn/config-schema"]
            }

            """#,
            #"""
            {
              "extends": "../../../../../tsconfig.base.json",
              "compilerOptions": { "outDir": "target/types" },
              "include": ["public/**/*", "server/**/*"],
              "kbn_references": ["@kbn/core", "@kbn/config-schema", "@kbn/core-http-browser"]
            }

            """#
        ),
    ]

    /// An empty context line is `\#(" ")`: git prints one space there, and a trailing space would not survive the
    /// linter.
    static let diffText = #"""
    diff --git a/x-pack/platform/plugins/shared/onechat/README.md b/x-pack/platform/plugins/shared/onechat/README.md
    index 3d829f5..d44fcad 100644
    --- a/x-pack/platform/plugins/shared/onechat/README.md
    +++ b/x-pack/platform/plugins/shared/onechat/README.md
    @@ -5,4 +5,5 @@ The chat's plugin: conversations, tools and attachments.
     ## Attachments
    \#(" ")
     Attachments go through the Kibana base path.
    -A very long line that the linter rejects because it goes on and on.
    +A shorter line.
    +Images over 5 MB are refused before upload.
    diff --git a/x-pack/platform/plugins/shared/onechat/public/components/upload_button.scss b/x-pack/platform/plugins/shared/onechat/public/components/upload_button.scss
    index 27665cc..7bef0eb 100644
    --- a/x-pack/platform/plugins/shared/onechat/public/components/upload_button.scss
    +++ b/x-pack/platform/plugins/shared/onechat/public/components/upload_button.scss
    @@ -1,8 +1,12 @@
     .onechatUploadButton {
       display: inline-flex;
    -  gap: 4px;
    +  gap: 8px;
    \#(" ")
       &__icon {
    -    color: $euiColorMediumShade;
    +    color: $euiColorPrimary;
    +  }
    +
    +  &--disabled {
    +    opacity: 0.5;
       }
     }
    diff --git a/x-pack/platform/plugins/shared/onechat/public/upload_image.test.ts b/x-pack/platform/plugins/shared/onechat/public/upload_image.test.ts
    new file mode 100644
    index 0000000..c280e38
    --- /dev/null
    +++ b/x-pack/platform/plugins/shared/onechat/public/upload_image.test.ts
    @@ -0,0 +1,10 @@
    +import { uploadImage } from './upload_image';
    +
    +describe('uploadImage', () => {
    +  it('prepends the base path', async () => {
    +    const http = { basePath: { prepend: (path: string) => `/base${path}` } };
    +    global.fetch = jest.fn().mockResolvedValue({ ok: true, json: async () => ({ id: '1', url: '/a' }) });
    +    await uploadImage(http as never, new File([''], 'a.png'));
    +    expect(global.fetch).toHaveBeenCalledWith('/base/api/chat/attachments', expect.anything());
    +  });
    +});
    diff --git a/x-pack/platform/plugins/shared/onechat/public/upload_image.ts b/x-pack/platform/plugins/shared/onechat/public/upload_image.ts
    index 39442f1..041585b 100644
    --- a/x-pack/platform/plugins/shared/onechat/public/upload_image.ts
    +++ b/x-pack/platform/plugins/shared/onechat/public/upload_image.ts
    @@ -19,10 +19,12 @@ export const uploadImage = async (
       http: HttpSetup,
       file: File
     ) => {
    -  const url = '/api/chat/attachments';
    +  const url = http.basePath.prepend('/api/chat/attachments');
    +  const headers = { 'kbn-xsrf': 'true' };
       // the proxy strips cookies on cross-origin requests
    -  const response = await fetch(url, { method: 'POST', body: file });
    +  const response = await fetch(url, { method: 'POST', body: file, headers, credentials: 'same-origin' });
       if (!response.ok) {
    +    throw new UploadError(response.status);
       }
       return (await response.json()) as UploadedImage;
     };
    @@ -59,4 +61,7 @@ export const hasImageExtension = (name: string): boolean =>
       imageExtensions.some((extension) => name.toLowerCase().endsWith(`.${extension}`));
    \#(" ")
     export class UploadError extends Error {
    +  constructor(public readonly status: number) {
    +    super(`upload failed: ${status}`);
    +  }
     }
    diff --git a/x-pack/platform/plugins/shared/onechat/server/routes/attachments.ts b/x-pack/platform/plugins/shared/onechat/server/routes/attachments.ts
    index ce7e72c..5b95a44 100644
    --- a/x-pack/platform/plugins/shared/onechat/server/routes/attachments.ts
    +++ b/x-pack/platform/plugins/shared/onechat/server/routes/attachments.ts
    @@ -6,7 +6,7 @@ export const registerAttachmentRoutes = (router: IRouter) => {
         {
           path: '/api/chat/attachments',
           validate: { body: schema.any() },
    -      options: { body: { maxBytes: 5 * 1024 * 1024 } },
    +      options: { body: { maxBytes: 5 * 1024 * 1024, accepts: ['image/*'] }, xsrfRequired: true },
         },
         async (context, request, response) => {
           const id = crypto.randomUUID();
    diff --git a/x-pack/platform/plugins/shared/onechat/tsconfig.json b/x-pack/platform/plugins/shared/onechat/tsconfig.json
    index a93feba..db838d9 100644
    --- a/x-pack/platform/plugins/shared/onechat/tsconfig.json
    +++ b/x-pack/platform/plugins/shared/onechat/tsconfig.json
    @@ -2,5 +2,5 @@
       "extends": "../../../../../tsconfig.base.json",
       "compilerOptions": { "outDir": "target/types" },
       "include": ["public/**/*", "server/**/*"],
    -  "kbn_references": ["@kbn/core", "@kbn/config-schema"]
    +  "kbn_references": ["@kbn/core", "@kbn/config-schema", "@kbn/core-http-browser"]
     }

    """#
}
