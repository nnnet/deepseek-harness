# Agent Note: Let a route declare the image encodings its endpoint decodes

Status: implemented

English | [中文](2026-08-24-request-image-media-type-negotiation.zh.md)

## Problem

`ImageRequestPolicy` bounded a request version by pixels and bytes only, so `attachment-local` chose its encoding purely on size: PNG for a low-colour source, WebP for anything with transparency, JPEG for an opaque photograph. A stored version already inside both budgets passed through untouched in whatever encoding normalization had produced, which is WebP for the same reasons.

WebP is decodable by every hosted endpoint this harness targets and by none of the llama.cpp-derived local servers, whose vision path decodes through `stb_image`. LM Studio answers such a request with `400 "'url' field must be a base64 encoded image."` — a decode failure reported as a malformed field.

A session log shows the cost. One 176×225 WebP request version, derived from a screenshot with transparency, ended seven consecutive turns over 67 minutes with that error. Every later turn resent the same history containing the same image, including turns whose user message had nothing to do with it, and the session only recovered when the operator switched providers by hand.

The wire format was never at fault: pi-ai already sends `image_url.url` as `data:<mimeType>;base64,<data>` (`dist/api/openai-completions.js`), which is what the OpenAI-compatible protocol specifies. Only the encoding inside that data URI was one the endpoint could not read.

## Decision

`ImageRequestPolicy` gains `mediaTypes`, the encodings a route's endpoint can decode. `attachment-local` filters its smallest-first encoding ladder to that set, re-encodes a stored version outside it instead of passing it through, and includes the accepted set in the request-version cache identity — `REQUEST_IMAGE_TRANSFORM_VERSION` moves to `request-image-v5` so two routes with different sets never share a cached variant.

Filtering can empty the ladder, because the smallest encoding for a class is not always the most portable one. A second ordered list answers that case: PNG carries transparency wherever WebP is refused, and JPEG joins it for a source with no transparency to lose. Only transparency can exhaust both lists, since policy validation admits at least one encodable media type and every one of them carries an opaque source; that case is refused with `UNSUPPORTED_IMAGE_TYPE` naming the accepted set.

`dsh-llm-pi-ai` exposes the set as the provider-route key `requestImageMediaTypes`, beside the `requestImagePixelBudget` and `requestImageMaxBytes` keys that already scope a route's request versions. It defaults to PNG, JPEG, and WebP — what the hosted OpenAI-compatible endpoints decode — and a local llama.cpp-derived route narrows it. This mirrors `defaultInput`: nothing can interrogate a gateway for what it accepts, so the deployment declares it and an over-claim is refused by the provider rather than by the harness. `dsh-llm-deepseek` states the same three as a module constant, because that adapter targets one vendor endpoint and the set is a property of that API rather than a deployment choice.

## Alternatives considered

**Send a bare base64 string rather than a data URI.** Rejected because pi-ai already sends a data URI and that is what the protocol specifies; LM Studio's error text names the `url` field but the failure is inside it. Changing the wire format would break every conforming endpoint to accommodate a misleading message.

**Drop WebP from the durable normalized form.** Rejected because the normalized attachment is provider-independent by design and is what every route derives from. Encoding it for the least capable possible consumer would enlarge the durable object and every request version derived from it, for every route, to accommodate the exception.

**Default `requestImageMediaTypes` to PNG and JPEG so a local server works untouched.** Rejected because it inverts the cost: WebP is the smallest of the three for screenshots and diagrams, so the default would enlarge every request body on every hosted route, permanently, to spare one deployment a one-line setting. The failure it prevents is loud and its message now names the setting.

**Detect the rejection and retry in another encoding.** Rejected because the provider's message is not a classifiable format failure — `'url' field must be a base64 encoded image` is indistinguishable from a genuinely malformed payload — and a retry ladder would re-send the whole conversation once per encoding on every request that carries an image.

**Transcode inside the pi-ai adapter instead of the attachment store.** Rejected because the request version is already cached, verified, and identified by the store; a second encoder in the adapter would duplicate the ladder, the alpha-compatibility check, and the byte-budget loop, and its output would sit outside the cache identity.

## Testing

`packages/attachment/attachment-local/tests/request-image.spec.ts` pins the four behaviors: a transparent source that encodes as WebP for a route accepting all three, and as PNG with transparency intact for a route accepting PNG and JPEG, under distinct variant ids; a stored WebP already inside both budgets re-encoded rather than passed through; an opaque source falling from its preferred JPEG to WebP for a WebP-only route; and the two refusals — a transparent source no accepted encoding carries, and a policy naming no encodable type at all.

`packages/llm/llm-pi-ai/tests/config.spec.ts` runs the settings-seam pair: the schema accepts an empty list as well-typed and the namespace validator refuses it, while a media type outside the encodable set fails the schema.

## Consequences

A deployment against a local llama.cpp-derived server sets one route key and its vision requests are accepted. Every route now carries its accepted set through the cache identity, so an existing request-image cache is re-derived once at the version bump. A route accepting fewer media types pays a second encode per request version, since the durable normalized form remains provider-independent. The declaration is unverified, like the modalities beside it: a route claiming an encoding its endpoint refuses still fails mid-turn, and the package README records that.
