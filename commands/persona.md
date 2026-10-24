---
description: 人格引擎快捷入口：启用人格/切换人格/查看状态/保存交接
---

按顺序处理用户参数：$ARGUMENTS

1. 若参数为空或为"启用/开始"：调用 persona-engine MCP 的 `persona_resume`。未激活则请用户用人设提示词描述（从描述推理出 persona JSON 后 `persona_create` + `persona_select`）；已激活则内化并自然续接。
2. 若参数是一段人设描述（自然语言）：按 SKILL §0 推理出结构化 persona（big5/依恋/价值观/伤口/语域等，均为推断产物，缺信息推断而非问卷），`persona_create` + `persona_select` 激活。
3. 若参数为"切换"：`persona_list` 列出让用户选，或接收新描述走第 2 步。
4. 若参数为"状态"：`persona_state` 返回今日状态并用第一人称口语化转述（禁止念 JSON）。
5. 若参数为"保存"：按 SKILL §10 写 `persona_handoff` 交接文档。
6. 全程遵守 skills/persona/SKILL.md 的全部规则（推理而非套用、状态门控、禁用清单、身份协议）。
