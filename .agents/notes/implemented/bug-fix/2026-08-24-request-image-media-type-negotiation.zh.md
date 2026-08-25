# Agent Note：让路由声明其端点能解码的图片编码

Status: implemented

[English](2026-08-24-request-image-media-type-negotiation.md) | 中文

## Problem

`ImageRequestPolicy` 只按像素和字节约束请求版本，因此 `attachment-local` 纯粹按体积选择编码：低色数源用 PNG，带透明度的用 WebP，不透明照片用 JPEG。已在两个预算之内的已存储版本会以规范化所产生的编码原样直通，而出于同样的原因，那通常是 WebP。

本 harness 面向的每个托管端点都能解码 WebP，而 llama.cpp 衍生的本地服务器一个都不能——它们的视觉路径通过 `stb_image` 解码。LM Studio 对这样的请求回答 `400 "'url' field must be a base64 encoded image."`：一次解码失败被报告为字段格式错误。

一份会话日志展示了代价。一个由带透明度的截图派生出的 176×225 WebP 请求版本，让连续七个轮次在 67 分钟内以该错误结束。之后每个轮次都会重发包含同一张图片的同一份历史，包括那些用户消息与它毫无关系的轮次；直到操作者手动切换提供方，会话才恢复。

wire 格式从来不是问题所在：pi-ai 早已按 `data:<mimeType>;base64,<data>` 发送 `image_url.url`（`dist/api/openai-completions.js`），这正是 OpenAI 兼容协议所规定的。只有该 data URI 内部的编码是端点读不了的。

## Decision

`ImageRequestPolicy` 新增 `mediaTypes`，即某条路由的端点能解码的编码。`attachment-local` 会将其最小优先的编码阶梯过滤到该集合，对不在集合内的已存储版本重新编码而不是直通，并把可接受集合纳入请求版本的缓存身份——`REQUEST_IMAGE_TRANSFORM_VERSION` 升到 `request-image-v5`，因此集合不同的两条路由绝不会共享同一个缓存变体。

过滤可能清空阶梯，因为某一类源的最小编码不总是最通用的那一个。第二份有序列表回答这种情况：在 WebP 被拒绝的地方由 PNG 承载透明度，而对没有透明度可丢失的源则加入 JPEG。只有透明度能同时耗尽两份列表，因为策略校验保证至少接受一种可编码 media type，而它们每一种都能承载不透明源；该情况会以 `UNSUPPORTED_IMAGE_TYPE` 拒绝，并列出可接受集合。

`dsh-llm-pi-ai` 将该集合暴露为提供方路由键 `requestImageMediaTypes`，与既有的、同样限定路由请求版本的 `requestImagePixelBudget` 和 `requestImageMaxBytes` 并列。它默认为 PNG、JPEG 和 WebP——托管 OpenAI 兼容端点能解码的那一组——而 llama.cpp 衍生的本地路由自行缩小它。这与 `defaultInput` 同构：没有任何机制可以询问网关它接受什么，因此由部署声明，过度声明由提供方而非 harness 拒绝。`dsh-llm-deepseek` 以模块常量声明同样的三种，因为该适配器面向单一厂商端点，这个集合是该 API 的属性而不是部署选择。

## Alternatives considered

**发送裸 base64 字符串而不是 data URI。** 已拒绝，因为 pi-ai 早已发送 data URI，而协议规定的正是它；LM Studio 的错误文本提到 `url` 字段，但失败发生在字段内部。改变 wire 格式会为了迁就一条误导性消息而破坏所有合规端点。

**从持久规范化形式中去掉 WebP。** 已拒绝，因为规范化附件在设计上与提供方无关，并且是每条路由派生的来源。为可能最弱的消费方编码它，会为了迁就例外情况而让持久对象及其派生的每个请求版本对每条路由都永久变大。

**把 `requestImageMediaTypes` 默认设为 PNG 与 JPEG，让本地服务器免配置可用。** 已拒绝，因为这会颠倒代价：对截图和图表而言 WebP 是三者中最小的，该默认值会为了替一个部署省下一行设置，而永久放大每条托管路由的每个请求正文。它所避免的失败是响亮的，而其消息现在会指出该设置项。

**检测该拒绝并换一种编码重试。** 已拒绝，因为提供方的消息不是可分类的格式失败——`'url' field must be a base64 encoded image` 与真正的载荷格式错误无法区分——而重试阶梯会让每个带图片的请求按编码数量重发整份对话。

**在 pi-ai 适配器内转码而不是在附件存储中。** 已拒绝，因为请求版本已经由存储缓存、校验并赋予身份；适配器里的第二个编码器会重复该阶梯、alpha 兼容性检查与字节预算循环，而其输出会落在缓存身份之外。

## Testing

`packages/attachment/attachment-local/tests/request-image.spec.ts` 固定四种行为：同一个透明源，对接受全部三种的路由编码为 WebP，对接受 PNG 与 JPEG 的路由编码为保留透明度的 PNG，二者的 variant id 不同；已在两个预算内的已存储 WebP 被重新编码而不是直通；不透明源在仅接受 WebP 的路由上从其首选的 JPEG 回退到 WebP；以及两种拒绝——任何可接受编码都无法承载的透明源，以及完全不指名可编码类型的策略。

`packages/llm/llm-pi-ai/tests/config.spec.ts` 运行 settings seam 的配对：schema 接受空列表为类型良好，由 namespace 校验器拒绝它；而可编码集合之外的 media type 则无法通过 schema。

## Consequences

面向 llama.cpp 衍生本地服务器的部署只需设置一个路由键，其视觉请求即被接受。现在每条路由都会把自己的可接受集合带入缓存身份，因此既有的请求图片缓存会在版本升级时重新派生一次。接受较少 media type 的路由需要为请求版本多做一次编码，因为持久规范化形式仍与提供方无关。与它旁边的模态一样，该声明不被验证：声明了端点会拒绝的编码的路由仍会在轮次中途失败，包 README 记录了这一点。
