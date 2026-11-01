# ADR 0004: Rendering compatibility and WebView trust boundaries

Status: selected design; **no production preview or demonstrated WebView sandbox is claimed**. The initial editor proof does not implement preview. These requirements are gates for the complete first release, not optional hardening.

Scope: [mobile plan sections 5.5 and 7](../mobile-client-plan.md), the editor boundary in [ADR 0003](0003-editor-protocol-and-durability.md), and managed resources in [ADR 0006](0006-import-share-and-privacy.md).

## Decision and threat model

Keep CodeMirror 6 and the fixed bundled renderer stack: markdown-it, DOMPurify, KaTeX and Mermaid. Pin exact package versions and integrity-locked transitive dependencies when their implementation lands; this ADR does not select unverified version/OS combinations. All JavaScript, CSS, fonts, worker code and icons ship in the application asset bundle. No CDN, runtime executable download, remote theme, network font or notebook-supplied plugin is permitted.

Treat every note, filename, link, diagram, SVG and attachment as hostile, including material imported from the user's own notebook. An attacker may control an entire notebook and try script execution, bridge forgery, path escape, network tracking, CSS-based leakage, navigation and memory/CPU exhaustion. This boundary is not a defense against a compromised OS or a WebView engine vulnerability; engine/platform updates remain necessary.

### Three principals

| Principal | Authority | Prohibited access |
| --- | --- | --- |
| Flutter application/native services | Own selected notebook/session, core operations, validated resource resolution and system navigation | Must not execute note-authored scripts or trust a WebView-supplied absolute path |
| Trusted editor WebView | Load bundled editor shell and narrow versioned editor channel bound to current session | No preview HTML, attachment DOM, network, arbitrary native method dispatch or notebook-provided code/CSS |
| Separate preview WebView | Render one bounded source snapshot with bundled renderers; receive host data one-way | **No registered native JavaScript command channel**, editor token, core handle, credential, filesystem root or privileged parent frame |

Use a separate preview WebView/controller and isolated origin/storage namespace, not a same-origin iframe inside the editor. Preview is unprivileged even if sanitization fails. Do not assume two WebViews use different OS processes; verify actual platform isolation without claiming process-level containment. Disable persistent preview cookies/storage where the platform permits; no functionality may depend on them. The host may deliver a bounded serialized render request or inspect trusted renderer completion, but preview content cannot call an application command bridge. Destroy the old preview generation on navigation/replacement and revoke its resource handles.

Note text is passed as JSON data to trusted entry points, never embedded in script source or raw document markup. Editor source is text/CodeMirror state, never `innerHTML`. Neither WebView may navigate to arbitrary pages, create popups, open child windows, start downloads, access camera/microphone/geolocation, use a service worker, or acquire file chooser permissions.

## Supported Markdown and renderer policy

| Component | Selected subset / configuration |
| --- | --- |
| markdown-it | CommonMark-style paragraphs/headings, emphasis, lists, quotes, fenced/indented code, thematic breaks, links and images; fixture-tested tables, strikethrough and read-only task-list display. `html: false`, `linkify: false`, `typographer: false`; do not rewrite source to fit the parser. Code highlighting uses bundled languages only; unknown fences remain escaped code. |
| Raw HTML | Disabled with **no first-release enable switch**. HTML tags, scripts, style tags and embedded SVG remain source/literal text, not rendered active content. |
| KaTeX | Inline `$...$` and block `$$...$$` math: ordinary symbols, fractions, roots, scripts, matrices and aligned equations covered by goldens. `trust: false`, `strict: 'error'`, `throwOnError: true`, `maxExpand: 1000`, `maxSize: 20`, `globalGroup: false`, fresh macro scope per expression. App-owned immutable macros only; no cross-note mutable macro dictionary. Catch failures and show escaped original source with a redacted unsupported-math label. No HTML/style/URL/image extension commands. |
| Mermaid | Fenced `mermaid` only; initially flowcharts and sequence diagrams with text labels and ordinary edges/messages. Explicit `securityLevel: 'strict'`, `startOnLoad: false`, `htmlLabels: false`, `maxTextSize: 32768`, `maxEdges: 500`. App-selected bundled layout/theme only. Reject frontmatter/init directives, click/callback/link directives, custom CSS/classes, external icons/images, HTML labels and all other diagram kinds before rendering. Do not fall back to Mermaid's loose mode. |
| Unsupported syntax | Preserve bytes in source; render escaped code/literal syntax or a clear unsupported-block placeholder with source access. Unsupported math/diagram output is not an editor failure and never changes the note. |

The exact supported syntax is the committed fixture corpus, not “everything supported by the current library.” markdown-it is not asserted to equal VNote's cmark fork. Pin expected HTML semantics and desktop compatibility against VNote `f8026adb4c43f78d90251148e24b6e72ca28f3d7`; differences require a narrow tested extension or supported renderer adapter, not schema/Markdown migration. Extensions cannot add a new trust boundary or network access.

Render and transform first, sanitize **last**. Run DOMPurify on the final composed HTML, generated SVG and MathML before insertion. Use explicit element/attribute allowlists for the selected subset, not DOMPurify's broad default profile. Block script, iframe, object, embed, form/input submission, meta/base, foreignObject, SVG animation, event attributes and custom elements; prefix generated IDs to prevent DOM clobbering. Task checkboxes are noninteractive display, not a native edit channel.

A URL-policy hook validates every URI-bearing attribute; SVG `href`/`xlink:href`, CSS references and MathML annotations are not exceptions. SVG references may target only same-diagram prefixed fragment IDs. Imported standalone SVG is not inserted inline: preserve it as an opaque attachment and offer explicit system export/open. Generated diagram SVG is separately constrained and sanitized. No library may reinterpret or modify sanitized markup afterward; any new generated subtree repeats the final policy pass.

DOMPurify is **not a CSS sanitizer**. Remove note-authored styles entirely. For required KaTeX/Mermaid-generated style attributes, parse CSS declarations with a fixed allowlist: layout dimensions/offsets, vertical alignment, font sizing/weight/style, line height, text alignment, colors and SVG stroke/fill geometry needed by goldens. Values must match bounded numeric units or approved identifiers/colors; reject URLs, `@` rules, imports, custom properties, `var()`, `attr()`, expressions and unknown functions/properties. Do not use a regular-expression blacklist. Bundle/scopingly generate approved stylesheet rules from trusted themes only. An output requiring unapproved styles becomes a visible unsupported block rather than weakening this policy.

References: [markdown-it security recommendations](https://github.com/markdown-it/markdown-it/blob/master/docs/security.md), [DOMPurify](https://github.com/cure53/DOMPurify) (including its warning about post-sanitization mutation), [KaTeX options](https://katex.org/docs/options.html), and [Mermaid configuration schema](https://mermaid.js.org/config/schema-docs/config.html). These references explain available controls; they do not prove the eventual pinned bundle is secure on either device.

## Resource resolution and navigation

Use app-owned, allowlisted local asset routing. The scheme/origin and any Swift/Kotlin adapter are implementation choices requiring actual `webview_flutter` platform audit; the labels “editor origin”, “preview origin” and “resource handle” here are **proposed concepts**, not invented plugin APIs or app identifiers. Do not use broad `file://` access, universal access from file URLs, an arbitrary-file HTTP server, or a network fallback.

1. Bundled executable assets resolve only through a build-generated manifest of exact packaged paths/media types. Notebook resources use a separate per-preview-generation opaque handle map prepared by the host, never expose sandbox absolute paths, and can serve data media only.
2. Resolve note-relative paths against the owning note's validated location and configured core assets layout. Decode URL encoding once, reject malformed encoding, NUL, controls, backslashes, drive/UNC paths and encoded separator ambiguities. Resolve `.`/`..` segments with a component stack; ordinary `../images/a.png` is allowed only when the final target stays within the managed notebook root. Reject any attempted escape, symlink/reparse traversal or file changed to a link after validation. Open through a containment-checked handle, not a check-then-follow path race.
3. Validate resulting MIME from bytes and extension; serve strict media types with no sniffing. Inline image subset is PNG/JPEG/WebP, validated before decode. Preserve other formats as attachments; never HTML-render an attachment because of its extension. The same normalized resource can be requested only within the published per-generation map and quotas. Absolute/custom external assets configurations that leave the managed root are preserved but not fetched; show an unsupported-resource explanation.
4. Block all remote fetches from both WebViews, including HTTP(S) images, CSS, fonts, SVG references, fetch/XHR, WebSocket, media, preload/prefetch and redirects. Remote-resource placeholders explain that the resource was not fetched; no “load remote images” exception in the first release. URL text sharing does not fetch a link preview.
5. Local fragments scroll inside preview. Notebook-relative note links and the fixture-supported VNote internal link syntax resolve to stable core IDs through the application navigation service. They are narrow navigation intents, not general custom-scheme execution; unsupported internal forms remain nonactive with explanation. The core ID resolver and compatibility fixtures define the actual syntax, not a new mobile scheme.
6. An external link requires a trusted user-activated navigation and host validation. Allow only absolute `https:`/`http:` links without userinfo or control characters; HTTP receives a plaintext warning. Open approved links through system browser UI, never in the editor/preview. Require a host confirmation showing a safely formatted origin before leaving the app; synthetic/scripted navigation has no authorization. Reject `javascript:`, `data:`, `blob:`, `file:`, `content:`, `intent:`, protocol-relative URLs, `mailto:`, `tel:` and unapproved custom schemes. The renderer/DOM cannot manufacture a trusted gesture. If the platform cannot supply sufficient gesture evidence, require an explicit Flutter confirmation rather than treating every navigation request as a tap.
7. Non-image attachments open only via a separate explicit host/system share action after MIME validation and disclosure that another app receives a copy. No automatic execution or direct grant to the live notebook.

## CSP and CodeMirror style requirements

Set CSP in the trusted shell before untrusted data is present, supported by native resource/navigation denial rather than relying on CSP alone. The selected baseline is:

- Both: `default-src 'none'; base-uri 'none'; object-src 'none'; frame-src 'none'; connect-src 'none'; media-src 'none'; form-action 'none'`. Deny framing in response policy where the local routing supports it. Native policy also forbids top-level navigation/window creation; CSP does not replace that policy.
- `script-src`: only the exact bundled shell origin, plus a per-load nonce if a bootstrap script is necessary. No `unsafe-inline`, `unsafe-eval`, remote sources, data scripts or notebook resource origins. Workers, if used, are exact bundled worker assets, not blobs or arbitrary URLs.
- `img-src` and `font-src`: exact approved local resource/bundle origins as applicable; no wildcard, remote, `data:` or `blob:` exception. Resource routing applies the narrower manifest and per-generation checks even when CSP allows the origin.
- `style-src`/`style-src-elem`: bundled styles plus a fresh nonce. Pass that nonce through CodeMirror's documented [`EditorView.cspNonce`](https://codemirror.net/docs/ref/#view.EditorView%5EcspNonce) for generated editor styles. Do not disable CodeMirror styles, weaken script policy, or assume static CSS alone covers runtime layout.
- `style-src-attr 'unsafe-inline'` is a deliberately limited exception for trusted CodeMirror positioning/measurement and the validated renderer-generated inline declarations described above. No note HTML/style can enter the editor; preview style attributes must pass the CSS value allowlist. This is not permission for arbitrary inline stylesheet elements or scripts.

CSP Level 3 style directives and nonce behavior must be checked against the final platform WebView/minimum-OS intersection. Do not assume a desktop browser result proves WKWebView/Android WebView behavior. If a platform ignores a needed directive, keep native denial and fail the gate until an equally restrictive, fixture-tested policy is selected; do not broadly add `unsafe-inline` to the script policy. Theme, dynamic text and reduced-motion updates use trusted configuration and do not reload the editor or mutate source/selection.

## Resource and work budgets

These are initial enforceable limits, not measured device results. Reuse the 4 MiB editor source ceiling; a 1 MiB representative note must preview without truncating its source.

| Resource | Limit and failure behavior |
| --- | --- |
| Render work | One active and one newest pending preview generation; coalesce older unstarted work. Never queue every keystroke. |
| Markdown | 4 MiB input, nesting depth 64, 100,000 tokens; reject excess with a visible source-mode explanation. |
| Result DOM | 16 MiB serialized output, 100,000 nodes, depth 64, attributes at most 8 KiB each; validate before insertion. |
| Math | At most 200 expressions; 8 KiB source and 256 KiB generated output per expression, plus KaTeX limits above. |
| Diagrams | At most 20 blocks; 32 KiB source, 200 nodes/participants, 500 edges/messages and 1 MiB SVG per block; no unbounded layouts. |
| Image | At most 16 MiB encoded bytes and 16 million pixels; reject excessive dimensions before full decode. Decoded resident image budget 64 MiB; lazy-load visible images and release offscreen images. |
| Resources | 200 distinct handles, 64 MiB total encoded bytes per preview, 4 concurrent reads, no unbounded retry or cache growth. |
| Watchdog | 2 seconds per math/diagram job, 5 seconds for a preview generation; cancel/tear down the unprivileged rendering context and show a failure rather than retry forever. |

Enforce input/token/object counts before expensive rendering wherever possible, and enforce output counts before DOM insertion. No timer on the same blocked JavaScript thread is a hard cancellation boundary: platform implementation must demonstrate that the host can stop/recreate a stalled preview while retaining the editor. Until demonstrated, report that limitation and do not claim the watchdog confines CPU. OOM/renderer termination must preserve editor/draft state. Errors reveal only category and limits, not note fragments, private paths or tokens.

## Rejected alternatives

- Preview inside the privileged editor DOM/same-origin iframe: one sanitizer failure would expose the editor bridge.
- Raw HTML toggle, Mermaid loose mode, unsanitized generated SVG, or broad DOMPurify defaults: incompatible with the threat model.
- Remote CDNs/images, universal file access, or arbitrary custom-scheme handlers: tracking, offline failure and filesystem exposure.
- CSS/script `unsafe-inline` everywhere to make CodeMirror render: conflates required trusted layout styles with executable content.
- Claiming cmark parity from a parser choice or claiming resource safety from a JavaScript timeout alone: unsupported by evidence.

## Observable acceptance cases (not executed)

1. Airplane-mode editor/preview/theme/font/math/diagram use makes zero network requests. Remote image, CSS URL, SVG reference, WebSocket and redirected-resource probes remain blocked even if CSP is deliberately bypassed in a test renderer.
2. Golden fixtures cover CommonMark/GFM subset, long single line, the 1 MiB note, CRLF/Unicode, relative/internal links, nested assets, unsupported syntax, KaTeX and both Mermaid kinds. Desktop round-trip source bytes never change through preview.
3. HTML/event-handler/script injection, malformed SVG/MathML, DOM clobbering and sanitizer mutation fixtures cannot execute code or access editor tokens/native command channels. Assert that no channel is registered on the preview controller.
4. Encoded traversal, sibling-prefix tricks, symlink swaps, wrong MIME, stale resource handles and external asset roots cannot read outside the selected managed notebook.
5. Scheme tricks and synthetic clicks cannot navigate either WebView or invoke native operations. An actual permitted link requires host policy/gesture confirmation and opens system UI only.
6. CSP remains enforced while CodeMirror cursors, selections, scrolling, IME, high contrast, light/dark themes and dynamic text render correctly on both target devices. Required nonce/styles are observed, not inferred from a desktop browser.
7. Every quota boundary and a diagram/macro bomb yields a visible non-destructive failure. The host watchdog remains responsive to a stalled renderer; preview recreation never resets source, undo or draft state.
8. Source errors and diagnostics contain no note body, private file path, URL credential or secret; unsupported blocks remain recoverable as exact source.
