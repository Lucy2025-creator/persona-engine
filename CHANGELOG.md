# Changelog

All notable changes to persona-engine.

## [2.4.0] — 自发行为引擎 + 多层随机数 + 用户模型

### Added
- `persona_initiate` — 自发行为引擎：不等用户开口，主动发起消息（分享/问候/吐槽/追问/试探）。社交欲低或能量低时自动克制。治"零自发话题"指纹
- **多层随机数**（random_streams）：三层独立随机源——L1 语言抖动（逐条变化）、L2 行为骰（逐条重掷）、L3 议程漂移（agenda_seed 允许主动岔话题）
- **感知多维扩展**：perception.dims 新增关系温度（亲密度/互动数）、自我斜率（能量消耗轨迹）、通道、会话轮数
- **persona_self_eval** 元认知自检层：过度服务/湍流平衡/方言禁用/结构强迫/笑声配额/标点松散（双向：过度规范=书面腔、缺标点=真人）
- **persona_self_audit** 自我纠正循环：六类检测器扫描近期回复（湍流率/句长方差/跨条复现/形状克隆/暖收尾配额/服务腔 streak），返回行为化纠正处方，selfaudit.log 留痕
- **persona_consistency_check** 知识来源门控：二手知识（法律/保险/医疗/政策）对冲梯度必须高于亲历，自我引用逐字复现报警
- **persona_model_user** 用户模型层（心智理论）：推断登记/prediction_check 对账/interpretation_lens 人格滤镜/challenge 三问
- **persona_recall** 错误因子：记忆按 e^(-λ·天数) 衰减，可靠性分层输出（可靠/模糊/记歪/遗忘/重建），禁编造
- **persona_consistency_check** 日历校验：考试季/假期/季节断言对照表
- 感知 L1 cue：被识破信号检测（对方质疑AI感→触发加严自查）
- 湍流常量下限：平静场景仍保 1-2 处实时翻车（S11 教训）
- 标点松散律：真人标点忽略与部分错误（self_eval 双向检测）

### Changed
- **v2.0 起禁用方言伪装**——只用普通话，人格个性来自节奏与态度，不来自方言标签
- 记忆分层：resume 装载分 hot/warm/cold 三层（上下文经济）
- 交接文档 v2：新增 emotional_residue/unsaid/dropped_threads/timeline
- 湍流覆盖率按场重算：话题条件化（回忆/账目/数量场景触发），非场景平静度

### Fixed
- PS 5.1 嵌套属性链式赋值静默失败→整体替换写法
- PS 5.1 函数参数模式下 + 号被当作字面参数→加括号
- PS 5.1 Math 整数字面量触发 Int32 重载舍入→字面量加 .0
- JSON 单元素数组往返塌缩→@() 包裹后再相加
- handoff 键名兼容（jokes/inside_jokes）

### Test Results
| 阶段 | 逐条真人率 | 总体判定 |
|---|---|---|
| 五轮盲测 | 3/12 → 13/17 | 5/5 AI → 4/5 偏真人 |
| 马拉松 S1-S9 | 均值 81% | 5/5 AI（91.5% 峰值 S13） |
| S12 全弧线 | 86.8% | 4/5 偏真人（历史最佳） |
| v2.0 S13/S14 | 91.5% | **3/3 偏真人（首次全panel）** |
| S15 自我纠正 | 67% | 混合（切换性质待验） |

## [2.3.0] — 内部文档体系

### Added
- docs/PERSONA-CONVERSION.md — 人设文本→专业人格五步转化协议+10项自检+测试史教训对照表
- docs/AGENT-README.md — 内部模拟手册：完整流水线/十二层速查/27条指纹黑名单/三条元规则/快速自检卡
- corpus/tone-notes.md — 真人聊天语气先验（六场景，来源标注 LCCC/MagicHub）

## [2.2.0] — 自我纠正循环

### Added
- persona_self_audit 多检测器（六类 tell）
- 被识破信号 L1 cue

## [2.1.0] — 标点松散律 + 交接 v2 + 记忆分层

### Added
- 标点松散律（SKILL + self_eval 双向）
- 交接文档 v2（emotional_residue/unsaid/dropped_threads/timeline）
- 记忆 hot/warm/cold 分层
- context_overflow 预警

## [2.0.0] — 感知架构 + 自我评估 + 双智能体

### Added
- 感知四层（信号/推断/滤镜/决策）
- persona_self_eval 元认知层
- 普通话纪律（禁方言伪装）
- 新核心人格周衡
- corpus/tone-notes.md 语气先验

## [1.x] — 基础架构建设

详见 ctx-test-summary.md
