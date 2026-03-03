# 迁移映射（VB6 -> DataHz 2.0）

最后更新：2026-03-03

## 核心能力映射

- `GetTableInfo` / `GetTableInfo_xlsx` / `GetTableInfo_LL_xlsx`
  - 对应 `ITemplateParser`
  - 当前实现：`LegacyIniTemplateParser`、`LegacyXlsxTemplateParser`
- `GetXZCode`
  - 对应 `IAreaCodeProvider`
  - 当前实现：`TextAreaCodeProvider`
- `FormatText`
  - 对应 `PlaceholderResolver`
- `SumTable` / `SumTable_LL` / `SumTable_To_Mdb`
  - 对应 `ITaskPlanner` + `IExecutionEngine`
- `OpenDB`
  - 对应 Access 执行引擎中的数据库连接流程
- `DoExpor` / `ExporToExcel`
  - 对应模板化导出与流向汇总写出

## 分阶段进展

1. 第一阶段（已完成）
   - 架构基线、INI 模板兼容、任务规划 API。
2. 第二阶段（已完成）
   - Access 连接与 SQL 执行引擎、列汇总流水线。
3. 第三阶段（已完成）
   - 标准/流向 XLSX 模板解析、模板导出、县级增量缓存、流向汇总文件生成。
4. 第四阶段（持续演进）
   - 异步任务队列、文件持久化、取消与统计。
   - API Key + JWT 鉴权与角色权限。
   - 外部密钥服务、动态密钥轮换、密钥运行态监控。
   - 审计链路、监控总览、Dashboard、发布加固脚本。

## 迁移风险控制

1. 模板语义优先保持与历史行为一致。
2. 使用历史模板样本建立回归包，对比 VB6 与 DataHz2 输出。
3. 以县级结果对齐作为验收基线，逐步扩大到地市/省级汇总。
