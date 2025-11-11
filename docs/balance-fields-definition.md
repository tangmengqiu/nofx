# Balance 和 Equity 字段定义说明

**文档目的**: 明确定义系统中所有余额相关字段的含义，避免混淆

**生成日期**: 2025-11-10

---

## 🎯 三个最核心的字段（快速参考）

### 1️⃣ `totalWalletBalance` - 总钱包余额

```
定义: 账户中"已实现"的资金
     = 初始存款 + 已实现盈亏（平仓结算的）
特点: 不包含浮盈浮亏，相对稳定
```

**示例**:
```
存入 10,000 USDT → 交易盈利平仓 +500 USDT
→ totalWalletBalance = 10,500 USDT
（持仓的浮盈浮亏不会影响这个数值）
```

---

### 2️⃣ `totalEquity` - 总权益/账户净值

```
定义: 账户的真实价值
     = totalWalletBalance + totalUnrealizedProfit
特点: 包含浮盈浮亏，实时波动
```

**示例**:
```
totalWalletBalance = 10,000 USDT
持仓浮盈 = +500 USDT
→ totalEquity = 10,500 USDT
（如果现在全平仓，余额就变成 10,500）
```

---

### 3️⃣ `availableBalance` - 可用余额

```
定义: 可用于开新仓的资金
     = totalEquity - 已占用保证金
特点: 可用于开仓，包含浮盈但减去占用
```

**示例**:
```
totalEquity = 10,500 USDT
持仓占用保证金 = 2,000 USDT
→ availableBalance = 8,500 USDT
（还能用 8,500 开新仓）
```

---

## 🔄 三者关系图

```
从交易所获取:
├─ totalWalletBalance (已实现资金) ────┐
└─ totalUnrealizedProfit (浮盈浮亏) ───┤
                                      ├─> totalEquity (总净值)
                                      │
系统计算:                              │
initialBalance (用户设定) ─────────────┼─> totalPnL = totalEquity - initialBalance
                                      │
totalMarginUsed (持仓占用) ────────────┴─> availableBalance = totalEquity - margin
```

---

## ⚠️ 关键区别对比

### **Wallet Balance vs Equity**

| 特性 | totalWalletBalance | totalEquity |
|------|-------------------|-------------|
| 含义 | 已实现资金 | 账户总净值 |
| 包含浮盈浮亏？ | ❌ 否 | ✅ 是 |
| 会实时波动？ | ❌ 否 | ✅ 是 |
| 平仓后更新？ | ✅ 是 | ✅ 是 |

**关键理解**:
- **有持仓时**: totalEquity 实时变化，totalWalletBalance 不变
- **平仓后**: 浮盈变已实现盈亏，两者都更新并趋于一致

---

## 📊 详细字段说明

### 从交易所 API 获取的字段

#### `totalWalletBalance` (总钱包余额)

**API 来源**:
- **Binance**: `account.TotalWalletBalance`
- **Hyperliquid**: 计算得出 = `accountValue - totalUnrealizedPnl`

**代码位置**:
- `trader/binance_futures.go:146`
- `trader/hyperliquid_trader.go:221`
- `trader/auto_trader.go:578,582`

---

#### `totalUnrealizedProfit` (总未实现盈亏)

**API 来源**:
- **Binance**: `account.TotalUnrealizedProfit`
- **Hyperliquid**: 累加所有持仓的 `position.UnrealizedPnl`

**计算公式** (对于单个持仓):
```
多单: unRealizedProfit = (markPrice - entryPrice) × quantity
空单: unRealizedProfit = (entryPrice - markPrice) × quantity
```

**代码位置**:
- `trader/binance_futures.go:148`
- `trader/hyperliquid_trader.go:184-188,225`
- `trader/auto_trader.go:579,585`

---

#### `availableBalance` (可用余额)

**API 来源**:
- **Binance**: `account.AvailableBalance`
- **Hyperliquid**: `accountState.Withdrawable` (优先) 或计算得出

**计算公式**:
```
availableBalance = totalEquity - totalMarginUsed
或展开为:
availableBalance = totalWalletBalance + totalUnrealizedProfit - totalMarginUsed
```

**代码位置**:
- `trader/binance_futures.go:147`
- `trader/hyperliquid_trader.go:200-216,224`
- `trader/auto_trader.go:580,588`

---

## 🧮 系统计算字段

### `totalEquity` (总权益 / 账户净值)

**计算公式**:
```
totalEquity = totalWalletBalance + totalUnrealizedProfit
```

**代码位置**:
- `trader/auto_trader.go:593` (buildTradingContext)
- `trader/auto_trader.go:1292` (GetAccountInfo)
- **API 返回**: `api/server.go:1330` 字段名 `total_equity`

---

### `totalPnL` (总盈亏，相对初始余额)

**计算公式**:
```
totalPnL = totalEquity - initialBalance
```

**代码位置**:
- `trader/auto_trader.go:680` (buildTradingContext)
- `trader/auto_trader.go:1319` (GetAccountInfo)
- **API 返回**: `api/server.go:1338` 字段名 `total_pnl`

---

### `totalPnLPct` (总盈亏百分比 / ROI)

**计算公式**:
```
totalPnLPct = (totalPnL / initialBalance) × 100
```

**代码位置**:
- `trader/auto_trader.go:681-684` (buildTradingContext)
- `trader/auto_trader.go:1320-1323` (GetAccountInfo)
- **API 返回**: `api/server.go:1339` 字段名 `total_pnl_pct`

---

### `initialBalance` (初始余额)

**来源**:
- 用户在创建交易员时设置
- 存储在数据库 `traders.initial_balance` 字段
- ⚠️ 可能被 auto-sync 功能自动更新（检测到充值/提现时）

**作用**:
- 作为计算 `totalPnL` 和 `totalPnLPct` 的基准

**代码位置**:
- `trader/auto_trader.go:220,232` (初始化)
- `trader/auto_trader.go:289-382` (auto-sync 可能修改)
- **API 返回**: `api/server.go:1341` 字段名 `initial_balance`

---

## 📝 完整计算示例

假设用户从 10,000 USDT 开始交易：

### 场景 1: 有浮盈的情况

```
用户操作:
1. 初始存入: 10,000 USDT
2. 开仓 BTC 多单，使用 2,000 USDT 保证金 (10x 杠杆)
3. BTC 价格上涨，持仓浮盈 500 USDT

字段计算:
• initialBalance        = 10,000 USDT          (用户设定)
• totalWalletBalance    = 10,000 USDT          (还没平仓结算)
• totalUnrealizedProfit = +500 USDT            (浮盈)
• totalEquity           = 10,000 + 500 = 10,500 USDT
• availableBalance      = 10,500 - 2,000 = 8,500 USDT
• totalPnL              = 10,500 - 10,000 = +500 USDT
• totalPnLPct           = (500 / 10,000) × 100 = +5%

用户看到的界面显示:
✅ Initial Balance: 10,000 USDT
✅ Total Equity: 10,500 USDT
✅ Available Balance: 8,500 USDT
✅ Total P&L: +500 USDT (+5%)
```

### 场景 2: 平仓后

```
用户操作:
4. 平掉 BTC 多单，浮盈变为已实现盈亏

字段计算:
• initialBalance        = 10,000 USDT          (不变)
• totalWalletBalance    = 10,500 USDT          (平仓后，盈利结算到钱包)
• totalUnrealizedProfit = 0 USDT               (没有持仓了)
• totalEquity           = 10,500 + 0 = 10,500 USDT
• availableBalance      = 10,500 - 0 = 10,500 USDT
• totalPnL              = 10,500 - 10,000 = +500 USDT
• totalPnLPct           = (500 / 10,000) × 100 = +5%

用户看到的界面显示:
✅ Initial Balance: 10,000 USDT
✅ Total Equity: 10,500 USDT
✅ Available Balance: 10,500 USDT (全部可用)
✅ Total P&L: +500 USDT (+5%)
```

### 场景 3: 充值后 (触发 auto-sync)

```
用户操作:
5. 从外部充值 1,000 USDT 到交易所账户

字段计算 (auto-sync 前):
• totalWalletBalance    = 11,500 USDT          (检测到增加)
• initialBalance        = 10,000 USDT          (旧值)
• totalPnL              = 11,500 - 10,000 = 1,500 USDT ❌ 错误!

字段计算 (auto-sync 后，检测到变化 >5%):
• totalWalletBalance    = 11,500 USDT
• initialBalance        = 11,500 USDT          (自动更新)
• totalPnL              = 11,500 - 11,500 = 0 USDT ✅ 正确!
• totalPnLPct           = 0%

用户看到的界面显示:
✅ Initial Balance: 11,500 USDT (已自动更新)
✅ Total P&L: 0 USDT (重新归零，因为基准变了)
⚠️ 注意: 历史 P&L 曲线会出现"断层"
```

---

## ⚠️ 常见混淆点

### 混淆1: `totalWalletBalance` vs `totalEquity`

**错误理解**: "它们是一样的"

**正确理解**:
- `totalWalletBalance`: **不含**浮盈浮亏，只有已实现资金
- `totalEquity`: **包含**浮盈浮亏，是账户真实净值

**区别场景**:
```
有持仓时:
  totalWalletBalance = 10,000 (不变)
  totalEquity = 10,500 (实时波动)

平仓后:
  totalWalletBalance = 10,500 (结算后更新)
  totalEquity = 10,500 (一致)
```

---

### 混淆2: `availableBalance` 的含义

**错误理解**: "可用余额 = 没有使用的钱"

**正确理解**:
- `availableBalance` = 可以用来开新仓的资金
- 它**包含**浮盈（但浮盈被"锁定"在持仓中）
- 它**不包含**已占用的保证金

**示例**:
```
totalEquity = 10,500 (含 500 浮盈)
totalMarginUsed = 2,000 (持仓占用)
→ availableBalance = 8,500

这个 8,500 中:
- 8,000 来自原始资金
- 500 来自浮盈（虽然还没平仓）
```

---

### 混淆3: `totalPnL` 的计算基准

**错误理解**: "总盈亏应该相对于 totalWalletBalance 计算"

**正确理解**:
- `totalPnL` 相对于 `initialBalance` 计算
- `initialBalance` 是用户设定的"起点"，不是实时余额
- 这样才能追踪"从开始到现在赚了多少"

**为什么不用 totalWalletBalance**:
```
如果用 totalWalletBalance:
  第1天: totalWalletBalance=10,000, totalPnL=0
  第2天: 盈利 500, totalWalletBalance=10,500, totalPnL=500 ✅
  第3天: 充值 1,000, totalWalletBalance=11,500, totalPnL=? ❌ 混淆!

如果用 initialBalance (固定):
  第1天: initialBalance=10,000, totalPnL=0
  第2天: totalEquity=10,500, totalPnL=500 ✅
  第3天: 充值后, initialBalance 不变, totalPnL 仍追踪交易盈亏 ✅

  (当然，auto-sync 可能会更新 initialBalance，这是另一个问题)
```

---

## 🔍 历史记录中的字段命名问题

### 问题根源

在保存历史记录时（`logger.DecisionRecord`），字段命名与实际存储内容不匹配：

```go
// trader/auto_trader.go:428-434
record.AccountState = logger.AccountSnapshot{
    TotalBalance:          ctx.Account.TotalEquity,    // ⚠️ 实际存的是 TotalEquity
    TotalUnrealizedProfit: ctx.Account.TotalPnL,       // ⚠️ 实际存的是 TotalPnL
    AvailableBalance:      ctx.Account.AvailableBalance, // ✅ 正确
}
```

### 字段映射表

| AccountSnapshot 字段 | 字段名暗示的含义 | 实际存储的内容 | 正确吗 |
|---------------------|----------------|--------------|--------|
| `TotalBalance` | 总余额（钱包余额） | **TotalEquity** (总净值) | ❌ 命名误导 |
| `TotalUnrealizedProfit` | 未实现盈亏（浮盈浮亏） | **TotalPnL** (总盈亏，相对初始余额) | ❌ 命名误导 |
| `AvailableBalance` | 可用余额 | **AvailableBalance** (可用余额) | ✅ 正确 |

### 这导致的问题

在读取历史记录时，如果按字段名理解，会得到错误的数据：

```go
// api/server.go:2256 (❌ 错误的理解)
totalEquity := record.AccountState.TotalBalance + record.AccountState.TotalUnrealizedProfit
// 实际计算的是: TotalEquity + TotalPnL
//               = TotalEquity + (TotalEquity - InitialBalance)
//               = 2×TotalEquity - InitialBalance ❌ 完全错误!

// 正确的理解:
totalEquity := record.AccountState.TotalBalance  // 这个字段实际就是 TotalEquity
totalPnL := record.AccountState.TotalUnrealizedProfit  // 这个字段实际是 TotalPnL
```

---

## 🎯 推荐的使用规范

### 前端显示

```typescript
// ✅ 推荐的显示方式
<StatCard title="Initial Balance" value={`${account.initial_balance} USDT`} />
<StatCard title="Total Equity" value={`${account.total_equity} USDT`} />
<StatCard title="Available Balance" value={`${account.available_balance} USDT`} />
<StatCard title="Total P&L" value={`${account.total_pnl} USDT (${account.total_pnl_pct}%)`} />
<StatCard title="Unrealized P&L" value={`${account.unrealized_profit} USDT`} />
```

### 计算公式验证

在开发和调试时，可以用这些公式验证数据一致性：

```typescript
// 验证1: totalEquity 的计算
assert(account.total_equity === account.wallet_balance + account.unrealized_profit)

// 验证2: totalPnL 的计算
assert(account.total_pnl === account.total_equity - account.initial_balance)

// 验证3: totalPnLPct 的计算
assert(Math.abs(account.total_pnl_pct - (account.total_pnl / account.initial_balance * 100)) < 0.01)

// 验证4: availableBalance 的合理性
assert(account.available_balance <= account.total_equity)
assert(account.available_balance >= 0)
```

---

## 📚 相关文档

- [Balance 和 P&L 计算逻辑问题分析](./balance-pnl-calculation-issues.md) - 发现的计算错误详情
- Binance Futures API 文档: https://binance-docs.github.io/apidocs/futures/en/
- Hyperliquid API 文档: https://hyperliquid.gitbook.io/hyperliquid-docs/

---

## 🔗 代码索引

### 字段定义位置

| 字段 | 定义位置 | 说明 |
|------|---------|------|
| `totalWalletBalance` | `trader/binance_futures.go:146` | Binance API 返回 |
| | `trader/hyperliquid_trader.go:221` | Hyperliquid 计算 |
| `totalUnrealizedProfit` | `trader/binance_futures.go:148` | Binance API 返回 |
| | `trader/hyperliquid_trader.go:184-188` | Hyperliquid 累加计算 |
| `availableBalance` | `trader/binance_futures.go:147` | Binance API 返回 |
| | `trader/hyperliquid_trader.go:200-216` | Hyperliquid 从 Withdrawable 获取 |
| `totalEquity` | `trader/auto_trader.go:593,1292` | 计算: wallet + unrealized |
| `totalPnL` | `trader/auto_trader.go:680,1319` | 计算: equity - initial |
| `totalPnLPct` | `trader/auto_trader.go:681-684,1320-1323` | 计算: (pnl / initial) × 100 |
| `initialBalance` | `trader/auto_trader.go:220,232` | 初始化时设置 |
| | `trader/auto_trader.go:370-371` | Auto-sync 更新 |

### API 返回位置

| API 端点 | Handler 位置 | 返回字段 |
|---------|------------|---------|
| `/api/account` | `api/server.go:1348-1378` | 所有账户信息 |
| `/api/equity-history` | `api/server.go:1508-1592` | 历史净值数据 |
| `/api/comparison` | `api/server.go:2232-2276` | 多交易员对比 |

---

**文档维护**: Claude Code Analysis
**最后更新**: 2025-11-10
**版本**: v1.0
