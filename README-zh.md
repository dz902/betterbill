# BetterBill

更有用的 AWS 账单分析。

# 概览

Amazon Cost and Usage Report (CUR) 是 AWS 云使用账单的最新版本。其结构经过重构，并且包含比以前的报告格式更多的数据。

然而，它仍然是一个具有数百列的宽表。每个服务都会重定义某些列，使得跨服务进行统一分析变得非常困难。缺乏详细的字段描述和可能的值也意味着你需要通过大量试验来弄清楚字段的确切语义。

BetterBill 是我对 CUR 报告可用性的改进。基本上，我们解构了宽表，并为服务的字段按意义创建别名，因此您只需查看字段名即可了解其含义。

此外，成本的计算方式也得到了统一。比如，Savings Plans 的计算方式与 Reserved Instance 和 On-Demand 的计算逻辑非常不同，但它们现在都在同一个模型下统一，因此您可以轻松分析 SP、RI 和 On-Demand 的使用情况。

此为个人爱好项目，仅供参考和试用，本人不承担任何使用相关责任。请自行注意任何可能产生的费用以及安全相关的要求。

# 快速开始

- 首先，你需要启用导出 CUR 的功能
  - 在控制台右上角点击进入 Billing 页面， 左侧 Cost Analysis > Data Exports 下，创建导出
  - 选择 Legacy CUR export
    - ❗️如果你找不到上述菜单，请左侧寻找 Cost & usage reports 菜单
    - ❗️注意不同区域的选项顺序可能有不同，请先看完下面的选项
  - 导出名字随意
  - 勾选 Include resource IDs
  - 不勾选 Split cost allocation data（暂不支持）
  - 时间粒度选择 Hourly / 按小时
  - 勾选 Refresh automatically
  - 数据格式，勾选 Parquet
  - 选择导出到 Amazon Athena
  - S3 桶，选择或创建一个均可
  - 稍等片刻，等状态从 In progress → Complete 后，你将可以在你选择的桶内看到 CUR
- 创建 BetterBill 专用数据库
  - 在 Athena 中执行如下 SQL 语句，如果没用过 Athena，需要先设置一下 Athena 的结果存储桶
    - `CREATE DATABASE bb;`
    - 这里的 `bb` 可以改为你喜欢的名字，后续可以配置


# 功能

- 按服务对字段进行语义别名
- 统一的成本计算模型
- RI、SP 被资源使用情况标记
  - 没用完的部分也可以被识别
-（计划中）数据完整性检查，确保转换后的成本正确
-（计划中）在 Amazon QuickSight 中展示使用情况，演示使用 BetterBill 可以实现的功能
-（开发中）一个用于轻松引导/升级 BetterBill SQL 视图到 Athena 的 boto3 脚本