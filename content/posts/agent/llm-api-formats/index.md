---
title: "LLM 对话 API 的请求、响应与流式事件"
date: 2026-11-24T13:00:00+08:00
draft: false
description: "用同一句话对照六种 LLM API 的 HTTP 报文，再用一个工具调用和一份带图请求讲清楚消息、内容块、流结束与 token 用量。"
tags: [ai generated, llm, agent gateway, sse]
categories: [agent]
---

同样是让模型把“你好”译成英文，OpenAI Chat 把 `Hello` 放在 `choices[].message.content`，Anthropic 把它放在一个 `text` 内容块里，Gemini 则把它放在候选答案的 `parts[]` 里。切到流式调用后，连“回答已经结束”和“token 用量已经到齐”都可能是两件先后发生的事。

下面用同一句翻译请求对照六种接口的普通响应和流式响应，再看 Agent 怎么调用天气工具，以及怎么在一条消息里发送图片和文字。示例中的 `MODEL_ID` 需要换成可用模型。响应和流式事件只展示相关字段，ID、分块位置和 token 数都是示意值。

## 一、先认接口，再找字段

| HTTP 接口 | 系统指令 / 对话输入 | 普通响应里的一段回答 | 流式文本在哪 |
| --- | --- | --- | --- |
| OpenAI Chat Completions | `messages[]` 里的 `developer` 或 `system` / `messages[]` | `choices[].message.content` | SSE · `choices[].delta.content` |
| OpenAI Responses | `instructions` / `input` | 消息项的 `content[].text`，取 `type=output_text` 的块 | SSE · `response.output_text.delta` 事件的 `delta` |
| Anthropic Messages | `system` / `messages[]` | `content[]` 中 `type=text` 的 `text` | SSE · `content_block_delta` 中的 `delta.text` |
| Gemini generateContent | `systemInstruction` / `contents[]` | `candidates[].content.parts[].text` | SSE · 同一字段，每次携带增量 |
| Amazon Bedrock Converse | `system[]` / `messages[]` | `output.message.content[].text` | AWS EventStream · `contentBlockDelta.delta.text` |
| Ollama 原生 Chat | `messages[]` 里的 `system` / `messages[]` | `message.content` | NDJSON · 每行的 `message.content` |

网关识别协议时，模型名只能作线索。比如 DeepSeek 和阿里云百炼都提供 OpenAI Chat 兼容入口，可以从 `choices[].message` 读回答。DeepSeek 还定义了 `reasoning_content` 单独承载推理内容。解析时先确认调用方使用的接口，再决定要读哪些扩展字段。[DeepSeek Chat Completions](https://api-docs.deepseek.com/api/create-chat-completion/) · [百炼 OpenAI Chat 兼容接口](https://help.aliyun.com/zh/model-studio/compatibility-of-openai-with-dashscope)

## 二、同一句话的六组报文

每组按 **请求体 → 普通响应 → 流式响应** 排列。前两者都用 JSON。看流式响应时先读 HTTP 的 `Content-Type`，`text/event-stream` 按 SSE 事件读，`application/x-ndjson` 按行读，`application/vnd.amazon.eventstream` 按二进制帧读。[SSE 规范](https://html.spec.whatwg.org/multipage/server-sent-events.html#event-stream-interpretation) · [Ollama 流式响应](https://docs.ollama.com/api/streaming) · [AWS EventStream 规范](https://smithy.io/2.0/aws/amazon-eventstream.html)

### 2.1 OpenAI Chat Completions · 消息和候选答案

`POST /v1/chat/completions`。应用把对话历史按顺序放进 `messages`。示例使用支持 `developer` 角色的模型来设置翻译要求。

```json
{
  "model": "MODEL_ID",
  "messages": [
    {"role": "developer", "content": "只给出译文。"},
    {"role": "user", "content": "把“你好”译成英文。"}
  ]
}
```

普通响应中，每个 `choice` 有自己的 `index`、消息和结束原因。这里读取 `index=0` 的回答。

```json
{
  "id": "chatcmpl_demo",
  "object": "chat.completion",
  "choices": [
    {"index": 0, "message": {"role": "assistant", "content": "Hello"}, "finish_reason": "stop"}
  ],
  "usage": {"prompt_tokens": 12, "completion_tokens": 1, "total_tokens": 13}
}
```

请求加上 `"stream":true` 和 `"stream_options":{"include_usage":true}` 后，一次正常结束的 SSE 流可以读到下面的片段。空行分隔事件。

```text
data: {"choices":[{"index":0,"delta":{"role":"assistant","content":"Hel"},"finish_reason":null}]}

data: {"choices":[{"index":0,"delta":{"content":"lo"},"finish_reason":null}]}

data: {"choices":[{"index":0,"delta":{},"finish_reason":"stop"}]}

data: {"choices":[],"usage":{"prompt_tokens":12,"completion_tokens":1,"total_tokens":13}}

data: [DONE]
```

把同一个 `index` 的 `delta.content` 依次拼起来，得到 `Hello`。收到 `finish_reason:"stop"` 时，这个候选的文本已经结束。继续读到 `choices:[]`，才能取到这次请求的用量。连接提前断开时，最后的用量事件可能缺失。[Chat Completions 请求与流式选项](https://developers.openai.com/api/reference/resources/chat/subresources/completions/methods/create)

### 2.2 OpenAI Responses · 输入和输出都是 item

`POST /v1/responses`。简单请求可以直接给 `input` 一个字符串。这里展开为消息和内容块，后面向同一条消息加图片或文件时还能沿用这个结构。

```json
{
  "model": "MODEL_ID",
  "instructions": "只给出译文。",
  "input": [
    {"role": "user", "content": [{"type": "input_text", "text": "把“你好”译成英文。"}]}
  ]
}
```

```json
{
  "id": "resp_demo",
  "status": "completed",
  "output": [
    {
      "type": "message", "id": "msg_demo", "role": "assistant",
      "content": [{"type": "output_text", "text": "Hello", "annotations": []}]
    }
  ],
  "usage": {"input_tokens": 12, "output_tokens": 1, "total_tokens": 13}
}
```

读原始 JSON 时先按 `output[].type` 找消息，再按 `content[].type` 找文本。SDK 里常见的 `response.output_text` 是把这些文本汇总起来的便捷属性。开启 `"stream":true` 后，下面三个阶段可能包含同一段回答。[Responses 对象与 SDK 取值示例](https://developers.openai.com/api/docs/guides/migrate-to-responses)

```text
event: response.output_text.delta
data: {"type":"response.output_text.delta","item_id":"msg_demo","output_index":0,"content_index":0,"delta":"Hel"}

event: response.output_text.delta
data: {"type":"response.output_text.delta","item_id":"msg_demo","output_index":0,"content_index":0,"delta":"lo"}

event: response.output_text.done
data: {"type":"response.output_text.done","item_id":"msg_demo","output_index":0,"content_index":0,"text":"Hello"}

event: response.completed
data: {"type":"response.completed","response":{"id":"resp_demo","status":"completed","output":[{"type":"message","id":"msg_demo","role":"assistant","content":[{"type":"output_text","text":"Hello"}]}],"usage":{"input_tokens":12,"output_tokens":1,"total_tokens":13}}}
```

`delta` 适合实时输出，`output_text.done.text` 是这个内容块的完整文本，`response.completed.response` 是整次调用的完成快照。审计若已累计 `Hel` 和 `lo`，收到后两者时可核对或补全该块。再追加一次就会把一次回答记成 `HelloHello`。遇到 `response.incomplete` 或 `response.failed`，要按实际终态记录。[Responses 流式事件](https://developers.openai.com/api/docs/guides/streaming-responses) · [API 原始事件示例](https://developers.openai.com/api/reference/resources/responses/methods/create)

### 2.3 Anthropic Messages · 一个消息包含多个内容块

`POST /v1/messages`。系统指令位于顶层 `system`，轮次放在 `messages` 中，请求带上 `max_tokens`。同一条消息的 `content` 可以写成一段文本，也可以展开成内容块数组。

```json
{
  "model": "MODEL_ID",
  "max_tokens": 64,
  "system": "只给出译文。",
  "messages": [
    {"role": "user", "content": [{"type": "text", "text": "把“你好”译成英文。"}]}
  ]
}
```

```json
{
  "id": "msg_demo",
  "type": "message",
  "role": "assistant",
  "content": [{"type": "text", "text": "Hello"}],
  "stop_reason": "end_turn",
  "usage": {"input_tokens": 12, "output_tokens": 1}
}
```

加上 `"stream":true` 后，`message_start` 开始一条消息，`content_block_start` 给一个内容块分配 `index`，后续增量归到该块。

```text
event: message_start
data: {"type":"message_start","message":{"id":"msg_demo","type":"message","role":"assistant","content":[],"usage":{"input_tokens":12,"output_tokens":0}}}

event: content_block_start
data: {"type":"content_block_start","index":0,"content_block":{"type":"text","text":""}}

event: content_block_delta
data: {"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"Hel"}}

event: content_block_delta
data: {"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"lo"}}

event: content_block_stop
data: {"type":"content_block_stop","index":0}

event: message_delta
data: {"type":"message_delta","delta":{"stop_reason":"end_turn"},"usage":{"output_tokens":1}}

event: message_stop
data: {"type":"message_stop"}
```

输入 token 可以在 `message_start.message.usage` 里出现，后面的 `message_delta.usage` 提供累计计数。例子里保留输入的 `12`，用最后看见的输出计数 `1` 更新该字段。工具参数也走 `content_block_delta`，但其类型是 `input_json_delta`，把它拼入回答会混入工具调用的 JSON。[Messages API](https://platform.claude.com/docs/en/api/messages/create) · [Anthropic 流式事件及用量](https://platform.claude.com/docs/en/build-with-claude/streaming)

### 2.4 Gemini generateContent · 候选答案里的 parts

`POST /v1beta/models/{model}:generateContent`。模型由 URL 选择。历史里的模型角色写作 `model`，一轮对话可以用多个 `parts` 混排文本和图片。

```json
{
  "systemInstruction": {"parts": [{"text": "只给出译文。"}]},
  "contents": [
    {"role": "user", "parts": [{"text": "把“你好”译成英文。"}]}
  ]
}
```

```json
{
  "candidates": [
    {"index": 0, "content": {"role": "model", "parts": [{"text": "Hello"}]}, "finishReason": "STOP"}
  ],
  "usageMetadata": {"promptTokenCount": 12, "candidatesTokenCount": 1, "totalTokenCount": 13}
}
```

流式调用换成 `POST /v1beta/models/{model}:streamGenerateContent?alt=sse`，请求体相同。每个 SSE 的 `data` 都是一个 `GenerateContentResponse`。流中的 `text` 是本次收到的片段，即使字段路径跟普通响应相同，也要按候选分别累积。

```text
data: {"candidates":[{"index":0,"content":{"role":"model","parts":[{"text":"Hel"}]}}]}

data: {"candidates":[{"index":0,"content":{"role":"model","parts":[{"text":"lo"}]},"finishReason":"STOP"}],"usageMetadata":{"promptTokenCount":12,"candidatesTokenCount":1,"totalTokenCount":13}}
```

`parts[]` 也可能携带函数调用或标记为 `thought:true` 的思考片段。只取面向用户的回答时应区分这些 part。如果输入被拦截，响应可能只有 `promptFeedback`，直接取 `candidates[0]` 会漏掉原因。[Gemini 请求、候选与内容块](https://ai.google.dev/api/generate-content) · [streamGenerateContent](https://aistudio.google.com/api-reference/generate-content/stream-generate-content)

### 2.5 Amazon Bedrock Converse · AWS EventStream

`POST /model/{modelId}/converse`。调用方选择 Bedrock 的 Converse 接口后，请求沿用下面的统一结构。即使底层选了 Claude，网关在此处看到的也是 Converse 报文。

```json
{
  "system": [{"text": "只给出译文。"}],
  "messages": [
    {"role": "user", "content": [{"text": "把“你好”译成英文。"}]}
  ]
}
```

```json
{
  "output": {"message": {"role": "assistant", "content": [{"text": "Hello"}]}},
  "stopReason": "end_turn",
  "usage": {"inputTokens": 12, "outputTokens": 1, "totalTokens": 13}
}
```

流式调用改用 `POST /model/{modelId}/converse-stream`。线上传输的是带长度和头部的 AWS 二进制事件帧。下面每行表示 **SDK 解帧后** 的一个事件，便于和其他协议对照。

```text
{"messageStart":{"role":"assistant"}}
{"contentBlockDelta":{"contentBlockIndex":0,"delta":{"text":"Hel"}}}
{"contentBlockDelta":{"contentBlockIndex":0,"delta":{"text":"lo"}}}
{"contentBlockStop":{"contentBlockIndex":0}}
{"messageStop":{"stopReason":"end_turn"}}
{"metadata":{"usage":{"inputTokens":12,"outputTokens":1,"totalTokens":13},"metrics":{"latencyMs":120}}}
```

`messageStop` 告诉调用方模型为什么停止，后续 `metadata` 才带上用量和延迟。网关只实现 SSE 分帧时，这种流还需要 AWS EventStream 解码器。[Converse](https://docs.aws.amazon.com/bedrock/latest/APIReference/API_runtime_Converse.html) · [Converse 流式顺序与实例](https://docs.aws.amazon.com/bedrock/latest/userguide/conversation-inference.html) · [AWS EventStream 帧格式](https://smithy.io/2.0/aws/amazon-eventstream.html)

### 2.6 Ollama 原生 Chat · 每行一个 JSON

`POST /api/chat`。该接口默认流式响应，显式给出 `"stream":false` 就会返回单个 JSON 对象。

```json
{
  "model": "MODEL_ID",
  "stream": false,
  "messages": [
    {"role": "system", "content": "只给出译文。"},
    {"role": "user", "content": "把“你好”译成英文。"}
  ]
}
```

```json
{
  "model": "MODEL_ID",
  "message": {"role": "assistant", "content": "Hello"},
  "done": true, "done_reason": "stop",
  "prompt_eval_count": 12, "eval_count": 1
}
```

把 `stream` 改成 `true` 后，响应类型为 `application/x-ndjson`。换行就是一条 JSON 记录的边界。

```ndjson
{"message":{"role":"assistant","content":"Hel"},"done":false}
{"message":{"role":"assistant","content":"lo"},"done":false}
{"message":{"role":"assistant","content":""},"done":true,"done_reason":"stop","prompt_eval_count":12,"eval_count":1}
```

最后一条即使文本为空，仍携带 `done` 和计数。运营日志里的输入、输出 token 可分别取 `prompt_eval_count` 和 `eval_count`。[Ollama Chat API](https://docs.ollama.com/api/chat) · [Ollama 流式编码](https://docs.ollama.com/api/streaming)

## 三、一次工具调用跨几条请求

假设用户问“杭州现在多少度？”，应用提供函数 `get_weather(city)`。模型第一次返回的是“请调用这个函数”，天气结果来自应用执行的工具。以 OpenAI Responses 为例，第一次 `POST /v1/responses` 声明函数及其参数。

```json
{
  "model": "MODEL_ID",
  "input": "杭州现在多少度？",
  "tools": [{
    "type": "function", "name": "get_weather", "description": "查询指定城市的气温",
    "parameters": {
      "type": "object", "properties": {"city": {"type": "string"}},
      "required": ["city"], "additionalProperties": false
    }
  }]
}
```

模型选中工具后，`function_call` 直接出现在 `output[]` 里。这里 `arguments` 是字符串，解码后才是对象 `{"city":"杭州"}`。

```json
{
  "id": "resp_weather_1",
  "output": [{
    "type": "function_call", "id": "fc_1", "call_id": "call_1",
    "name": "get_weather", "arguments": "{\"city\":\"杭州\"}"
  }]
}
```

假设工具返回 18°C。应用再发一次请求，用 `previous_response_id` 接上第一轮，用 `call_id` 标明结果属于哪次函数调用。如果同时查两个城市，每个结果都要带回对应的调用 ID。

```json
{
  "model": "MODEL_ID",
  "previous_response_id": "resp_weather_1",
  "input": [
    {"type": "function_call_output", "call_id": "call_1", "output": "{\"temperature_c\":18}"}
  ]
}
```

第二次响应才可能在 `output_text` 块里出现“杭州现在是 18°C。”。对审计而言，第一轮有用户问题和工具调用、第二轮有工具结果和自然语言答复，两轮各有自己的响应 ID 和 token 用量。[OpenAI 函数调用往返](https://developers.openai.com/api/docs/guides/function-calling)

换成 Anthropic，同一个工具结果会以 **user 消息** 的身份回到模型。第二次请求的 `messages` 数组可以长这样。

```json
[
  {"role":"user","content":"杭州现在多少度？"},
  {"role":"assistant","content":[{"type":"tool_use","id":"toolu_1","name":"get_weather","input":{"city":"杭州"}}]},
  {"role":"user","content":[{"type":"tool_result","tool_use_id":"toolu_1","content":"18°C"}]}
]
```

如果审计字段叫“用户最后问了什么”，倒序取最后一条 `role:user` 会选中 `18°C`。这条记录的内容块类型是 `tool_result`，继续往前找到用户写的文本，才会取到“杭州现在多少度？”。[Anthropic 工具结果与消息顺序](https://platform.claude.com/docs/en/agents-and-tools/tool-use/handle-tool-calls)

| 接口 | 应用在哪里声明函数 | 模型在哪里发起调用 | 应用怎样回填结果 |
| --- | --- | --- | --- |
| OpenAI Chat | `tools[].function` | `message.tool_calls[]`，`function.arguments` 是 JSON 字符串 | 在历史中保留调用消息，再追加 `role:"tool"`，用 `tool_call_id` 对应调用的 `id` |
| OpenAI Responses | `tools[]` 中的 `type:"function"` | `output[]` 中的 `function_call`，`arguments` 是 JSON 字符串 | `input[]` 中的 `function_call_output` 带回同一个 `call_id` |
| Anthropic | `tools[]` 的 `name` 和 `input_schema` | assistant 的 `tool_use` 内容块，`input` 是对象 | 下一条 user 消息带 `tool_result` 块，以 `tool_use_id` 指向调用块的 `id` |
| Gemini | `tools[].functionDeclarations[]` | model 的 `parts[].functionCall`，`args` 是对象 | `parts[].functionResponse` 回填函数名与 `response` 对象，调用带 `id` 时回传相同的 `id` |
| Bedrock Converse | `toolConfig.tools[].toolSpec` | assistant 的 `content[].toolUse`，`input` 是结构化值 | user 的 `content[].toolResult` 带 `toolUseId` 和结果内容块 |
| Ollama | `tools[].function` | `message.tool_calls[].function`，`arguments` 是对象 | 追加 `role:"tool"` 的消息，用 `tool_name` 标明函数名，`content` 放结果 |

同一个“杭州”在不同协议里可能已经是对象中的值，也可能还在一段 JSON 字符串里。流式工具参数还可以拆到多个事件里，例如 Anthropic 用同一 `index` 的 `partial_json` 依次传来 `{"city":` 和 `"杭州"}`。把调用标识对应好、拼完再解码，才能得到完整参数。[Chat 工具字段](https://developers.openai.com/api/reference/resources/chat/subresources/completions/methods/create) · [Anthropic 工具结果](https://platform.claude.com/docs/en/agents-and-tools/tool-use/handle-tool-calls) · [Gemini 函数调用和结果字段](https://ai.google.dev/api/generate-content) · [Bedrock 工具结果](https://docs.aws.amazon.com/bedrock/latest/APIReference/API_runtime_ToolResultBlock.html) · [Ollama 工具调用](https://docs.ollama.com/capabilities/tool-calling)

## 四、图片和文件在 HTTP body 的哪里

用户发一张票据，接着问“总金额是多少？”。在 OpenAI Chat 中，这可以是一条消息、两个按顺序排列的内容块。

```json
{
  "model": "MODEL_ID",
  "messages": [{
    "role": "user",
    "content": [
      {"type": "image_url", "image_url": {"url": "https://example.com/receipt.jpg", "detail": "low"}},
      {"type": "text", "text": "总金额是多少？"}
    ]
  }]
}
```

同一张图用 URL 传递时，请求体里只有地址。把 URL 换成 `data:image/jpeg;base64,` 开头的值，整张图片的编码就进了这一个 JSON 字符串。Anthropic Messages 把内联图片放在 `type:"image"` 块的 `source.data` 里。Gemini 用 `parts[].inlineData` 的 `mimeType` 和 `data`，引用已上传文件则可用 `fileData.fileUri`。[OpenAI 视觉输入](https://developers.openai.com/api/docs/guides/images-vision) · [Anthropic 视觉输入](https://platform.claude.com/docs/en/build-with-claude/vision) · [Gemini 图像输入](https://ai.google.dev/gemini-api/docs/image-understanding)

PDF 也可以把上传与推理拆成两次 HTTP 调用。先向 `POST /v1/files` 发 `multipart/form-data`，表单里有 `purpose` 和二进制 `file`。拿到返回的文件 ID 后，再向 `POST /v1/responses` 发普通 JSON。下面的 `file_demo` 代表上传响应返回的 ID。

```json
{
  "model": "MODEL_ID",
  "input": [{
    "role": "user",
    "content": [
      {"type": "input_file", "file_id": "file_demo"},
      {"type": "input_text", "text": "总金额是多少？"}
    ]
  }]
}
```

这对网关审计有一个直接影响。遇到 50 MiB 内联图片，只截取整个 body 的前 8 KiB，取到的几乎都是图片编码，排在后面的用户问题也会丢失。按内容块扫描，就可以跳过图片数据，继续读出“总金额是多少？”。而对上面的文件 ID 请求，这次推理报文只提供文件引用，文件本身要到上传请求里找。[OpenAI Files 上传](https://developers.openai.com/api/reference/resources/files/methods/create) · [Responses 文件输入](https://developers.openai.com/api/docs/guides/file-inputs)

## 五、网关审计怎样还原一条回答

回到 `Hello` 的例子。假设 Envoy 的一次 body 回调在 `data: {"cho` 处结束，下次回调才收到这条 JSON 的其余字节、空行和下一条事件的开头。此时要区分三个边界。

1. **传输边界**由 HTTP 和代理的读取时机决定。一个回调可以包含半条、多条或恰好一条应用事件。
2. **事件边界**由线上编码决定。SSE 遇到空行后派发事件，同一事件的多行 `data:` 按规范用换行连接。NDJSON 按行取 JSON。AWS EventStream 按二进制帧长度解码。[SSE 分帧规则](https://html.spec.whatwg.org/multipage/server-sent-events.html#event-stream-interpretation) · [NDJSON 响应](https://docs.ollama.com/api/streaming) · [AWS EventStream](https://smithy.io/2.0/aws/amazon-eventstream.html)
3. **业务边界**由协议字段决定。Chat 按 choice 汇总文本，Responses 可按 `output_index` 和 `content_index` 归到具体内容块，Anthropic 按块的 `index` 处理。若只记录最终回答，工具参数、思考片段和已经处理过的完成快照各有自己的去处。

这样，两段文本 `Hel` 和 `lo` 可以还原成一份回答 `Hello`，也可以和稍后才出现的用量写在同一条审计记录里。示例中两个文本事件对应的服务端计数是一个输出 token。审计记录应采用服务端实际返回的计数，缺失时保留“未知”。关于网关如何在不同提供商之间转换协议，可接着读本站的 [AgentGateway LLM 模块深度解析](../agent-gateway-llm/)。
