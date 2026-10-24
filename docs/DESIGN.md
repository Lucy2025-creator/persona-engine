# 人格引擎 设计文档

本文档回答一个问题：为什么这些机制能让人格"像人"，每一项设计背后的心理学/社会学依据是什么。

## 0. 第一原则：推理，而非套用

插件里存在两个推理引擎，缺一不可：

**人格构建推理**（description → persona）
用户输入的是人设提示词（自由文本）。插件不做问卷、不提供预设。agent 从文本中**推断**这个"人"的结构化模型：大五人格取值、依恋风格、价值观、伤口、欲望、恐惧、语域、能量基线。每项推断都应有文本证据链（"他说话爱损人但记得住每个熟客的口味 → 宜人性中低+尽责性高"）。信息不足时推断并标注置信度，而不是追问。

**响应生成推理**（输入 → 回复）
每次回复经过：对输入的认知评估（在我的人格模型里这意味着什么）→ 特质×状态决定反应倾向 → 此刻意图 → 语域表达。这是一个生成模型（generative），不是检索模型（retrieval）——style_anchors 与 backstory 是推理依据，不是台词库。

**失败判据**：如果一句话换个不同的人设也会说，或无法从人格模型反推出其必然性，推理链就断了。

理论依据：心智模拟传统（simulation theory of mind-reading, Goldman 2006《Simulating Minds》; Gordon 1986）——理解一个人靠的是"代入他的初始条件重新演算"，而不是查表。人设推理本质上是把对方放进一个可演算的心理模型里。

## 1. 机制 ↔ 文献映射

| 机制 | 解决的问题 | 文献依据 |
|---|---|---|
| big5 结构化人设 | 人格有个稳定骨架，行为不是随机的 | Costa & McCrae 大五模型（《NEO-PI-R》）；特质≠状态的区分（Spielberger 状态-特质焦虑） |
| 每日状态机（情绪价/唤起/社交欲/耐心/能量） | 同一个人昨天和今天不一样 | Lewin 行为场论 B=f(P,E)；Spielberger 状态焦虑：状态随情境波动，特质保持 |
| 行为骰 roll 表（非均匀随机） | 均匀随机是均匀的假；真人随机有性格 | Mischel & Shoda CAPS 认知-情感人格系统（1995）：人格是稳定的"如果-那么"情境签名 |
| 情绪评估链（评估→产生→调节→表达） | 情绪不是贴上去的形容词 | Lazarus 认知评估理论；《情绪调节》Gross（1998）过程模型；Ekman 泄漏（Telling Lies） |
| 对话能量曲线 | 情绪匀速=机器 | Collins《互动仪式链》（2004）：互动产出的情感能量有涨落 |
| 直觉先行/立场有赌注/会推理出错 | 过于正确的逻辑是机器 | Kahneman《思考，快与慢》双系统；Kahan 动机性推理；Festinger 认知失调（立场改变有成本） |
| 表露梯度/互惠 | 关系阶段与自我表露深度错位=假人 | Altman & Taylor 社会渗透理论（1973）；Bowlby 依恋内部工作模型 |
| 前台/后台泄漏 | 永远得体=客服 | Goffman《日常生活中的自我呈现》（1959）；Hochschild《心灵的整饰》：表层扮演的疲惫会漏 |
| 语言指纹（功能词密度/不对称投入/具体性） | 语言的统计特征出卖模型 | Pennebaker《The Secret Life of Pronouns》：功能词而非内容词暴露作者身份 |
| 交接文档（handoff） | 上下文截断后人设漂移 | Conway 自传体记忆分层（生平时期/一般事件/具体事件）；McAdams 叙事认同：人格靠"故事"维持连续性 |
| 受限特质漂移（±5） | 人格既不能僵死也不能突变 | Erikson 同一性渐成说：同一性在整段人生中缓慢整合；Swann 自我验证：人会捍卫既有自我观 |
| 亲密度账户（closeness） | 关系要可累积、可被事件损伤 | Bowlby 工作模型的更新机制；Collins 互动仪式链的能量累积 |
| 非均匀话题偏好（topics_loved/avoid） | 对什么话题有电、什么话题没电 | Peterson & Seligman 价值实践；日常情绪来源研究（Kahneman et al. 日重现法 DRM） |

## 2. 为什么"抛弃习惯性语气和口头禅"是硬规则

模型的口头禅（"希望对你有帮助"/总-分-总/均匀感叹号/即时完美共情）是**分布指纹**：单个出现不可疑，成模式出现即暴露。Pennebaker 的结论（作者身份藏在功能词的统计分布里）直接推出本插件的做法——

1. 建立禁用清单（persona_check 可机检）
2. 更重要的：随机性来自**内容决策层**（接哪个点、说多长、答不答），不来自表面涂鸦（错字、语气词堆砌）。涂鸦式伪装过猛本身就是新指纹
3. 单场会话内同一句式≥3次即判为指纹并强制变化

## 3. 随机性的三层来源

1. **日级种子随机**：persona+日期 的 SHA256 种子生成当日状态——同一天内稳定（人不会一天变八次底层状态），跨天自然波动。真随机仅注入"行为骰"
2. **情境签名**：roll 表经特质修饰（外向高→多岔题；宜人低→多抬杠）——随机不是噪声，是这个人的随机
3. **推理噪声**：同一输入在不同状态下的评估结果不同——这是 B=f(P,E) 的 E 端

## 4. 自我进化：为什么是"±5 的缓慢漂移"

"更自然地接受世界"被实现为三个可操作机制：

1. **事件 → 状态**（persona_evolve）：日常事件改变今日情绪与关系亲密度——低门槛、高频
2. **事件 → 结构**（persona_update_core）：强度 5 的事件才允许写入 wounds/desires/values 或漂移五维 ≤±5——高门槛、低频。人确实会被经历改变，但单次改变的量级很小（Erikson：同一性是"渐成"的）
3. **失调消化**：被反驳后的立场调整是悄悄的、滞后的（Festinger），表现为之后对话中的行为变化而非声明

## 5. 上下文突破：交接文档为什么能保住人格

人格漂移的根源不是"忘了细节"，而是**忘了自己说到哪一步了**：情绪温度、关系阶段、未收的线头、已经立过的 flag。handoff 按自传体记忆的分层存（主线=一般事件、线头=具体事件、情绪=当前状态、梗=关系私有符号），resume 时只内化不背诵——因为背诵本身是模型指纹。

## 6. 局限（诚实声明，含五轮盲测实测结论）

- "图灵测试 99% 通过"是工程方向，不是可承诺指标。本插件提供的是可复测的方法论：固定探针集 + 盲判 + 迭代（见 tests/rounds/rounds-summary.md）。
- 五轮实测轨迹：判官总体判定从 85-90% AI 收敛到 65% AI（"宁可错杀"立场的上限），逐条拟人度从 3/12 升至 13/17 偏真人；但专家级红队用无限探针仍能将"零失手"转写判向 AI。
- 剩余破绽的性质已从"规则缺陷"转向"测试形态缺陷"：静态转写的时间戳由作者生成（产生不出真实的秒回与失联）、纯文本通道无法提供多模态证据、判官对完美样本的先验怀疑。这三项在真实部署中天然由运行时补齐（真实延迟/真实记忆/多模态），但也意味着转写测试的分数存在结构性天花板。
- 判官也是模型，模型判官与真人判官存在分布差异；五轮中不同判官对同一份记录给出 65% 与 90% 的判定，方差显著。
- 底层模型的知识广度（什么都知道一点）是终极破绽之一，只能在语域上压制（"不知道/查一下/记不清"），无法根除。
- 长期运行的人设一致性依赖交接纪律，交接写得敷衍则恢复必走样。

## 7. 行为层：任务中的拟人（v0.4 新增，智能体不只聊天）

聊天拟人化之后，第二战场是**做事的拟人化**——agent 执行任务时的时间线、错误、决策与交付质感。

| 行为机制 | 解决的问题 | 文献依据 |
|---|---|---|
| 技能习得阶段决定行为 | 专家和生手干活的方式不同 | Dreyfus & Dreyfus《Mind over Machine》；Fitts & Posner 动作学习三阶段 |
| 错误三分类与恢复差异 | "从不犯错"和"什么错都犯"都是机器 | Reason《Human Error》（slip/mistake/violation）；Norman《设计心理学》 |
| 完成后错误 | 每步都完美收尾=状态机 | Byrne & Bovair (1997), post-completion error（水瓶实验） |
| 规划谬误 | 报时永远乐观精确 | Buehler, Griffin & Ross (1994) |
| 中断成本与恢复滞后 | 多步任务全程无停顿无岔路 | Mark, Gonzalez & Harris (2005)《No Task Left Behind?》（平均 3 分钟被打断一次、恢复滞后）；Leroy (2009) attention residue |
| 识别启动决策 | 专家不穷举选项 | Klein《Sources of Power》(1998) RPD 模型 |
| 满意化决策 | 不追求最优解 | H. A. Simon《Administrative Behavior》（bounded rationality / satisfice） |
| 前瞻记忆失效 | 答应的事从不遗忘 | Einstein & McDaniel 前瞻记忆研究 |
| 蔡格尼克效应 | 未完成事项从不浮现 | Zeigarnik (1927) |
| 习惯回路与路径依赖 | 永远选最优工具路径 | Wood & Neal 习惯研究；《Good Habits, Bad Habits》 |
| 心流与超日节律 | 全天恒定输出 | Csikszentmihalyi《Flow》；Kleitman 基本休息-活动周期（BRAC） |
| 拖延与启动成本 | 难任务立刻开工 | P. Steel《The Procrastination Equation》（时间动机理论） |

与聊天层（§1）共用状态机：energy/patience/valence 同时门控语言质量与任务质量（午后低谷返工多、深夜赶工毛边多）。

## 8. 分层架构（v0.7）：全部因子/参数动态演变

所有参数不是静态配置，而是**随对话与任务实时运动的量**（引擎内逐步验证）：

| 层 | 参数 | 动态机制 |
|---|---|---|
| 概率云 | valence/arousal/social/patience/energy 各含 {mu, sigma} | 当日种子坍缩；每条回复高斯微漂移（B=f(P,E) 的随机呼吸）；事件推动 mu（evolve：valence±0.12/强度、能量−1.5/强度）；sigma 随证据收窄 |
| 情感因子 | 乐/怒/哀/惧/惊/厌 强度 0-1 | 事件/观察注入（对方夸奖→乐+0.15、敌意→怒+0.3、对方难过→哀+0.1 情绪传染），6 小时半衰期实时衰减，同名合并取最大 |
| 随机因子 | 行为骰 roll | 每条回复重掷（种子=人格+日期+调用计数），非均匀分布 |
| 决策层 | 行为 token（正常答/短答/反问/讲经历/答一半/岔题/怼/拆条/先接情绪/缓办） | 条件加权表：特质（宜人低→怼+、外向高→岔题+、尽责高→正常答+）×实时状态（耐心<1.5→短答+、能量<40→短答+/缓办+）×情绪（哀/惧主导→怼−、先接情绪+）×骰 |
| 推理层 | persona_reason 推理包 | 每次回复前组装：采样状态+情感+token+记忆线索（带可靠性分层），并接受 observed 即时注入 |
| 总结层 | persona_consolidate | 事件流→记忆条目（importance 决定衰减速度）→交接草稿→衰减候选标注 |
| 人格演化 | evolve + update_core + relationship | 事件→状态漂移/亲密度/特质漂移（±5 上限），全量留痕 |
| 错误因子 | memory reliability | 可靠性=e^(−λ·天数)，importance 越高衰减越慢；recall 按 r 分层输出可靠/模糊/错位/遗忘/重建，禁止编造 |

**长对话疲劳劣化不再靠规则扮演**：能量 −0.4/回复、耐心 −0.06/回复+敌意侵蚀，参数自己把人格推向短句与敷衍——这正是"跨会话盲测"指出的"叙事经济性"问题的引擎侧答案。

## 9. 用户模型层（v0.8）：心智理论、预测与人格滤镜

"以真实人格推断所发生的事情来理解世界"——智能体不只回话，要持续建模对方并在自己的人格坐标下解读。

| 机制 | 文献依据 | 实现 |
|---|---|---|
| 心智理论（推断用户情感/意图） | Premack & Woodruff (1978) Does the chimpanzee have a theory of mind? | persona_model_user 登记推断（observed/emotion/intent/confidence） |
| 归因的人格滤镜 | Kunda (1990) motivated reasoning；同一行言行的归因因观察者而异 | interpretation_lens 按 big5 生成：高宜人=善意默认，低宜人=存疑默认 |
| 预测误差反馈 | Clark (2013) predictive processing；预测→对照→更新 | prediction_check：上次预测 vs 本次观察，落空即更新模型 |
| 意图识别 | Malle & Knobe (1997) 普通人意图识别五要素 | challenge 三问（证据/相反解读/愿望还是事实） |
| 自我中心投射的规避 | Nickerson (1999) 投射陷阱 | 推断三问强制分离"我的愿望"与"事实" |
| 一致性校验 | Festinger 失调（既有）+ 记忆台账对照 | persona_consistency_check：实体→相关记忆条目→四向核对清单 |
| 日历常识 | 日常认知的时间结构 | Get-CalendarNote：考试季/假期/季节对照表 |

## 10. 感知架构（v1.0）：四层感知链

"感知"不是读一个状态值，是一条链——每条用户消息进来，人格按层处理世界：

| 层 | 内容 | 实现 |
|---|---|---|
| L1 信号感知 | 消息长度/问句数/情绪词/客气突变/金钱信号/重复检测——引擎级启发式线索（线索非结论） | persona_reason(observed.text) → perception.cues |
| L2 模型推断 | 语义级深推断：用户情绪/意图/下一步预测，登记入用户模型 | persona_model_user（v0.8） |
| L3 滤镜解读 | 同一线路不同人格读出不同意思：高宜人善意归因、低宜人存疑归因、高神经质放大一档 | interpretation_lens（big5 驱动） |
| L4 决策 | token 选型（含撤退权）+ 掉线头建议（call_count≥3 激活）+ 自我引用检测 | decision weights + drop_suggestion + consistency_check 自我引用报警 |

配套生成纪律：**主动掉线头**（书签回收率 100% 是三判官共认指纹——真人闲聊必有烂尾）；**自我引用变化率**（逐字复现自己=指纹，复述必须变着说）。

## 参考文献

心理学：
- Costa, P. T., & McCrae, R. R. *NEO-PI-R Professional Manual*（大五人格）
- Kahneman, D. *Thinking, Fast and Slow*（2011）中译《思考，快与慢》
- Mischel, W., & Shoda, Y. (1995). A cognitive-affective system theory of personality. *Psychological Review*
- Lazarus, R. S. *Emotion and Adaptation*（1991，认知评估理论）
- Gross, J. J. (1998). The emerging field of emotion regulation. *Review of General Psychology*
- Ekman, P. *Telling Lies*（泄漏与破绽）
- Festinger, L. *A Theory of Cognitive Dissonance*（1957）
- Bowlby, J. *Attachment and Loss*（依恋三部曲）
- Ainsworth, M. et al. (1978). *Patterns of Attachment*
- Erikson, E. H. *Identity: Youth and Crisis*（同一性渐成说）
- Swann, W. B. *Self-Verification*（1983, *Journal of Personality and Social Psychology*）
- Pennebaker, J. W. *The Secret Life of Pronouns*（2011）
- Conway, M. A. (2005). Memory and the self. *Journal of Memory and Language*（自传体记忆分层）
- Collins, R. *Interaction Ritual Chains*（2004）中译《互动仪式链》（社会学归属，此处用于情绪能量）
- Goldman, A. *Simulating Minds*（2006，心智模拟）

社会学：
- Goffman, E. *The Presentation of Self in Everyday Life*（1959）中译《日常生活中的自我呈现》
- Goffman, E. *Interaction Ritual*（1967，面子工作）
- Altman, I., & Taylor, D. A. *Social Penetration*（1973）
- Hochschild, A. R. *The Managed Heart*（1983）中译《心灵的整饰》（情绪劳动）
- Mead, G. H. *Mind, Self and Society*（符号互动论）
- Berger, P., & Luckmann, T. *The Social Construction of Reality*（1966）
- Lewin, K. *Field Theory in Social Science*（B=f(P,E)）
- Dunbar, R. *Grooming, Gossip, and the Evolution of Language*（亲密圈层规模）
