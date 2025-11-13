# Trader 生命周期完整流程文档

> 本文档详细描述 nofx 交易系统中 Trader 从启动到停止的完整生命周期

## 目录

- [1. 系统启动阶段](#1-系统启动阶段)
- [2. TraderManager 初始化](#2-tradermanager-初始化)
- [3. AutoTrader 创建](#3-autotrader-创建)
- [4. 交易员启动](#4-交易员启动)
- [5. 交易周期执行](#5-交易周期执行)
- [6. 订单执行流程](#6-订单执行流程)
- [7. 平仓与 PNL 计算](#7-平仓与-pnl-计算)
- [8. 回撤监控](#8-回撤监控)
- [9. 停止流程](#9-停止流程)
- [10. 数据流架构](#10-数据流架构)
- [11. 关键时间节点](#11-关键时间节点)
- [12. 核心数据结构](#12-核心数据结构)

---

## 1. 系统启动阶段

### 流程图

```
main()
 ├─ 加载 .env 环境变量
 ├─ 初始化数据库 (config.db)
 ├─ 初始化加密服务 (RSA密钥)
 ├─ 同步 config.json 到数据库
 ├─ 加载内测码到数据库
 ├─ 设置 JWT 密钥
 ├─ 配置币种池 (默认币种/AI500/OI Top)
 ├─ 创建 TraderManager
 ├─ 从数据库加载所有交易员配置
 ├─ 启动 API 服务器 (默认8080端口)
 ├─ 启动行情 WebSocket 监控
 └─ 等待 Ctrl+C 退出信号
```

### 关键步骤说明

1. **环境变量加载**: 从 `.env` 文件读取配置（可选）
2. **数据库初始化**: 创建或打开 SQLite 数据库 `config.db`
3. **加密服务**: 加载 RSA 密钥用于敏感信息加密（API Key等）
4. **配置同步**: 将 `config.json` 中的配置同步到数据库
5. **币种池设置**:
   - 默认主流币种：BTC, ETH, SOL 等
   - AI500 动态币种池（可选）
   - OI Top 持仓量排行（可选）
6. **API 服务器**: 启动 HTTP REST API，提供 Web 界面访问
7. **行情监控**: WebSocket 连接交易所，实时获取价格数据

### 代码位置

- `main.go:153-360`

---

## 2. TraderManager 初始化

### 流程图

```
NewTraderManager()
 └─ 创建空的 traders map

LoadTradersFromDatabase(database)
 ├─ 获取所有用户ID
 ├─ 遍历每个用户
 │   ├─ 获取用户的交易员配置
 │   ├─ 获取AI模型配置 (DeepSeek/Qwen/Custom)
 │   ├─ 获取交易所配置 (Binance/Hyperliquid/Aster)
 │   ├─ 解密API密钥
 │   └─ 创建 AutoTrader 实例
 └─ 存储到 traders map (key: trader.ID)
```

### 关键步骤说明

1. **用户遍历**: 支持多用户系统，每个用户可配置多个交易员
2. **AI 模型配置**:
   - DeepSeek: 默认 AI 提供商
   - Qwen: 阿里云通义千问
   - Custom: 自定义 API（支持 OpenAI 兼容接口）
3. **交易所配置**:
   - Binance: 币安合约交易
   - Hyperliquid: 去中心化永续合约
   - Aster: 另一个交易平台
4. **密钥解密**: 使用 RSA 解密数据库中的加密 API 密钥
5. **实例管理**: 所有 Trader 存储在 `map[string]*AutoTrader` 中

### 代码位置

- `manager/trader_manager.go:41-334` (加载配置)
- `manager/trader_manager.go:429-442` (StartAll 方法)

---

## 3. AutoTrader 创建

### 流程图

```
NewAutoTrader(config, database, userID)
 ├─ 验证配置参数 (ID, Name, AIModel)
 ├─ 初始化 MCP 客户端
 ├─ 根据配置创建 AI 客户端
 │   ├─ Custom API
 │   ├─ Qwen (阿里云)
 │   └─ DeepSeek (默认)
 ├─ 设置币种池 API
 ├─ 根据 Exchange 创建对应的 Trader 接口
 │   ├─ Binance: NewFuturesTrader()
 │   ├─ Hyperliquid: NewHyperliquidTrader()
 │   └─ Aster: NewAsterTrader()
 ├─ 验证初始余额 > 0
 ├─ 初始化决策日志记录器
 └─ 返回 AutoTrader 实例
```

### 关键组件

1. **MCP Client**: AI 调用的统一接口
2. **Trader 接口**: 抽象不同交易所的操作
   ```go
   type Trader interface {
       GetBalance() (map[string]interface{}, error)
       GetPositions() ([]map[string]interface{}, error)
       OpenLong(symbol string, quantity float64, leverage int) (map[string]interface{}, error)
       OpenShort(symbol string, quantity float64, leverage int) (map[string]interface{}, error)
       CloseLong(symbol string, quantity float64) (map[string]interface{}, error)
       CloseShort(symbol string, quantity float64) (map[string]interface{}, error)
       SetStopLoss(symbol string, price float64) error
       SetTakeProfit(symbol string, price float64) error
   }
   ```
3. **决策日志**: 每次 AI 决策都会保存到 `decision_logs/{trader_id}/` 目录

### 代码位置

- `trader/auto_trader.go:154-284`

---

## 4. 交易员启动

### 流程图

```
AutoTrader.Run()
 ├─ 设置运行状态 isRunning = true
 ├─ 初始化 stopMonitorCh 通道
 ├─ 记录启动时间
 │
 ├─ ===== PNL 系统恢复 =====
 │   ├─ restorePNLFromDB()
 │   │   ├─ 查询 orders 表汇总数据
 │   │   │   SELECT SUM(realized_pnl), SUM(commission)
 │   │   │   FROM orders WHERE trader_id = ?
 │   │   ├─ 恢复 totalRealizedPnL
 │   │   └─ 恢复 totalCommission
 │   └─ 日志: "累计盈亏: XX USDT, 手续费: XX USDT"
 │
 ├─ ===== 仓位同步 =====
 │   ├─ syncPositionsRuntime()
 │   │   ├─ getExchangePositions() - 从交易所 API 获取持仓
 │   │   ├─ getPositionsFromDB() - 从 orders 表计算持仓
 │   │   │   SELECT symbol, side,
 │   │   │          SUM(CASE WHEN reduce_only=0 THEN remaining_quantity ELSE 0 END) AS qty,
 │   │   │          AVG(CASE WHEN reduce_only=0 THEN avg_price ELSE NULL END) AS entry
 │   │   │   FROM orders
 │   │   │   WHERE trader_id = ? AND remaining_quantity > 0
 │   │   │   GROUP BY symbol, side
 │   │   ├─ findOrphanPositions() - 对比找出孤儿仓位
 │   │   │   • 交易所有但数据库没有 → 完全孤儿
 │   │   │   • 数量不匹配 → 部分孤儿
 │   │   └─ handleOrphanPositionsRuntime() - 创建虚拟订单接管
 │   │       ├─ 转换为 PnLVirtualOrderInfo
 │   │       ├─ database.PnLCreateVirtualOrdersOnRuntime()
 │   │       └─ 设置 source = "MANUAL_IMPORT"
 │   └─ 日志: "仓位同步完成，无孤儿仓位" 或 "发现 N 个孤儿仓位"
 │
 ├─ ===== 账户对账 =====
 │   ├─ verifyAccountBalance()
 │   │   ├─ 获取交易所余额 (totalWalletBalance, totalUnrealizedProfit)
 │   │   ├─ 计算本地净值:
 │   │   │   calculatedEquity = initialBalance + realizedPnL + unrealizedPnL
 │   │   ├─ 交易所净值:
 │   │   │   exchangeEquity = walletBalance + unrealizedPnL
 │   │   └─ 对比差异 (容忍度: 0.1 USDT)
 │   └─ 日志: "账户对账通过: Equity=XXX" 或 "Equity mismatch: Diff=XXX"
 │
 ├─ ===== 启动监控 =====
 │   └─ startDrawdownMonitor()
 │       └─ goroutine: 每 1 分钟检查持仓回撤
 │           ├─ checkPositionDrawdown()
 │           ├─ 触发条件: 收益 > 5% && 回撤 >= 40%
 │           └─ emergencyClosePosition()
 │
 └─ ===== 主循环 =====
     ├─ ticker: 按 config.ScanInterval 触发 (默认3分钟)
     ├─ 首次立即执行 runCycle()
     └─ for isRunning {
         ├─ select {
         │   ├─ case <-ticker.C: runCycle()
         │   └─ case <-stopMonitorCh: 退出
         └─ }
```

### 关键机制

#### 4.1 PNL 系统恢复

**目的**: 系统重启后恢复历史盈亏状态，确保数据连续性

**实现**:
```sql
-- 恢复已实现盈亏
SELECT SUM(realized_pnl) AS total_pnl, SUM(commission) AS total_fee
FROM orders
WHERE trader_id = ?
```

**容错**: 如果恢复失败，初始化为 0（日志警告）

#### 4.2 仓位同步

**目的**: 检测用户手动操作（如在交易所网页手动开仓），防止数据不一致

**孤儿仓位类型**:
1. **完全孤儿**: 交易所有持仓，但 orders 表没有记录
2. **部分孤儿**: 数量不匹配（如手动加仓）

**处理方式**:
- 创建虚拟订单（`is_synthetic = 1, sync_source = 'MANUAL_IMPORT'`）
- 不重置 PNL 字段，保留历史数据
- 接管后按正常仓位管理

#### 4.3 账户对账

**目的**: 验证本地计算的净值与交易所实际净值是否一致

**公式**:
```
本地净值 = 初始余额 + 累计已实现盈亏 + 当前未实现盈亏
交易所净值 = 钱包余额 + 当前未实现盈亏

差异 = |本地净值 - 交易所净值|
```

**容忍度**: 0.1 USDT（考虑浮点精度和手续费延迟）

### 代码位置

- `trader/auto_trader.go:288-350` (Run 主流程)
- `trader/auto_trader_pnl.go:15-158` (仓位同步)
- `trader/auto_trader_pnl.go:360-406` (PNL 恢复 & 对账)
- `trader/auto_trader.go:1534-1630` (回撤监控)

---

## 5. 交易周期执行

### 流程图

```
runCycle()
 ├─ callCount++ (第 N 次调用)
 ├─ 创建决策记录 (DecisionRecord)
 │
 ├─ 1️⃣ 检查风控暂停
 │   └─ if time.Now().Before(stopUntil):
 │       ├─ 日志: "风险控制：暂停交易中"
 │       └─ return
 │
 ├─ 2️⃣ 重置日盈亏
 │   └─ if time.Since(lastResetTime) > 24h:
 │       ├─ dailyPnL = 0
 │       └─ lastResetTime = time.Now()
 │
 ├─ 3️⃣ 构建交易上下文
 │   └─ buildTradingContext()
 │       ├─ 获取账户信息
 │       │   ├─ trader.GetBalance()
 │       │   ├─ totalEquity = walletBalance + unrealizedProfit
 │       │   └─ availableBalance, marginUsed
 │       │
 │       ├─ 获取持仓信息
 │       │   ├─ trader.GetPositions()
 │       │   ├─ 跳过 quantity = 0 的"幽灵持仓"
 │       │   ├─ 计算盈亏百分比 (考虑杠杆)
 │       │   │   pnlPct = ((markPrice - entryPrice) / entryPrice) × leverage × 100
 │       │   ├─ 跟踪持仓首次出现时间 (positionFirstSeenTime)
 │       │   └─ 获取历史最高收益率 (peakPnLCache)
 │       │
 │       ├─ 获取候选币种池
 │       │   └─ getCandidateCoins()
 │       │       ├─ 用户自定义币种 (tradingCoins)
 │       │       ├─ 系统默认币种 (BTC/ETH/SOL/BNB等)
 │       │       ├─ AI500 动态币种 (可选)
 │       │       └─ OI Top 持仓量排行 (可选)
 │       │
 │       ├─ 获取市场数据 (K线、指标)
 │       │   └─ market.Get(symbol)
 │       │       ├─ 15分钟K线 (最近100根)
 │       │       ├─ RSI, MACD, EMA
 │       │       └─ 成交量、波动率
 │       │
 │       ├─ 分析历史表现
 │       │   └─ decisionLogger.AnalyzePerformance(100)
 │       │       ├─ 胜率、平均盈亏
 │       │       ├─ 最大回撤
 │       │       └─ 交易频率
 │       │
 │       └─ 返回 Context 结构
 │
 ├─ 4️⃣ 调用 AI 决策
 │   └─ decision.GetFullDecisionWithCustomPrompt()
 │       ├─ 构建系统提示词 (基于模板)
 │       │   ├─ "default": 标准策略
 │       │   ├─ "adaptive": 自适应策略
 │       │   └─ "aggressive": 激进策略
 │       ├─ 构建用户提示词
 │       │   ├─ 账户状态 (余额、持仓、盈亏)
 │       │   ├─ 市场数据 (价格、K线、指标)
 │       │   └─ 候选币种列表
 │       ├─ 调用 AI API (DeepSeek/Qwen/Custom)
 │       ├─ 解析 AI 响应 (JSON 格式)
 │       │   {
 │       │     "cot": "思维链分析",
 │       │     "decisions": [
 │       │       {
 │       │         "action": "open_long",
 │       │         "symbol": "BTCUSDT",
 │       │         "reasoning": "技术指标看涨",
 │       │         "leverage": 3,
 │       │         "position_size_usd": 100,
 │       │         "stop_loss": 95000,
 │       │         "take_profit": 105000
 │       │       }
 │       │     ]
 │       │   }
 │       └─ 返回 Decision 列表
 │
 ├─ 5️⃣ 对决策排序
 │   └─ sortDecisionsByPriority()
 │       ├─ 优先级规则:
 │       │   1. close_long, close_short (平仓)
 │       │   2. partial_close (部分平仓)
 │       │   3. update_stop_loss, update_take_profit (调整止损止盈)
 │       │   4. open_long, open_short (开仓)
 │       │   5. hold, wait (观望)
 │       └─ 目的: 防止仓位叠加超限
 │
 └─ 6️⃣ 执行决策
     └─ for each decision:
         ├─ executeDecisionWithRecord()
         │   ├─ open_long → executeOpenLongWithRecord()
         │   ├─ open_short → executeOpenShortWithRecord()
         │   ├─ close_long → executeCloseLongWithRecord()
         │   ├─ close_short → executeCloseShortWithRecord()
         │   ├─ update_stop_loss → executeUpdateStopLossWithRecord()
         │   ├─ update_take_profit → executeUpdateTakeProfitWithRecord()
         │   ├─ partial_close → executePartialCloseWithRecord()
         │   └─ hold/wait → 无操作
         ├─ 记录执行结果到 DecisionRecord
         └─ 延迟 1 秒 (防止交易所限流)
```

### Context 结构

```go
type Context struct {
    CurrentTime     string        // 当前时间
    RuntimeMinutes  int           // 运行时长（分钟）
    CallCount       int           // AI 调用次数
    BTCETHLeverage  int           // BTC/ETH 杠杆倍数
    AltcoinLeverage int           // 山寨币杠杆倍数

    Account AccountInfo           // 账户信息
    Positions []PositionInfo      // 持仓列表
    CandidateCoins []CandidateCoin // 候选币种
    Performance *PerformanceAnalysis // 历史表现
}

type AccountInfo struct {
    TotalEquity      float64  // 总权益
    AvailableBalance float64  // 可用余额
    TotalPnL         float64  // 总盈亏（USDT）
    UnrealizedPnL    float64  // 未实现盈亏
    TotalPnLPct      float64  // 总盈亏百分比
    MarginUsed       float64  // 已用保证金
    MarginUsedPct    float64  // 保证金使用率
    PositionCount    int      // 持仓数量
}

type PositionInfo struct {
    Symbol           string   // 币种
    Side             string   // 方向 (long/short)
    EntryPrice       float64  // 开仓价
    MarkPrice        float64  // 标记价
    Quantity         float64  // 数量
    Leverage         int      // 杠杆
    UnrealizedPnL    float64  // 未实现盈亏（USDT）
    UnrealizedPnLPct float64  // 未实现盈亏百分比
    PeakPnLPct       float64  // 历史最高收益率
    LiquidationPrice float64  // 强平价
    MarginUsed       float64  // 占用保证金
    UpdateTime       int64    // 更新时间（毫秒）
}

type CandidateCoin struct {
    Symbol        string   // 币种
    Price         float64  // 当前价格
    Change24h     float64  // 24小时涨跌幅
    Volume24h     float64  // 24小时成交量
    RSI           float64  // RSI 指标
    MACD          string   // MACD 状态
    EMA           string   // EMA 趋势
    Volatility    float64  // 波动率
    KLineData     []KLine  // K线数据
}
```

### 代码位置

- `trader/auto_trader.go:364-543` (runCycle 主流程)
- `trader/auto_trader.go:546-699` (buildTradingContext)
- `trader/auto_trader.go:702-1207` (执行决策)

---

## 6. 订单执行流程

### 开多仓流程 (executeOpenLongWithRecord)

```
executeOpenLongWithRecord(decision)
 ├─ 1️⃣ 防重复检查
 │   └─ 检查是否已有同币种同方向持仓
 │       ├─ trader.GetPositions()
 │       └─ if exists: return error "拒绝开仓以防止仓位叠加超限"
 │
 ├─ 2️⃣ 获取市场价格
 │   └─ market.Get(symbol)
 │       └─ price = marketData.Price
 │
 ├─ 3️⃣ 计算开仓数量
 │   └─ quantity = positionSizeUSD / price
 │       例: 100 USDT / 50000 = 0.002 BTC
 │
 ├─ 4️⃣ 设置杠杆倍数
 │   └─ trader.SetLeverage(symbol, leverage)
 │       ├─ Binance: /fapi/v1/leverage
 │       ├─ Hyperliquid: 隐式（通过保证金计算）
 │       └─ Aster: API 参数
 │
 ├─ 5️⃣ 执行开仓
 │   └─ order = trader.OpenLong(symbol, quantity, leverage)
 │       ├─ Binance:
 │       │   ├─ CreateOrder(MARKET, BUY, positionSide=LONG)
 │       │   └─ 返回 CreateOrderResponse {
 │       │       OrderID, ClientOrderID, Symbol, Status,
 │       │       AvgPrice, ExecutedQuantity, Commission
 │       │     }
 │       ├─ Hyperliquid:
 │       │   ├─ CreateOrderRequest(IOC, IsBuy=true, ReduceOnly=false)
 │       │   ├─ order.Exchange.Order(ctx, request)
 │       │   └─ 从 OrderStatus.Filled 提取:
 │       │       AvgPx (成交均价)
 │       │       TotalSz (成交数量)
 │       │       Oid (订单ID)
 │       └─ Aster:
 │           └─ POST /api/order/place
 │
 ├─ 6️⃣ 记录订单到数据库
 │   └─ recordOrderWithRetry(order, symbol, "LONG", reduceOnly=false)
 │       └─ recordOrder()
 │           ├─ 提取字段:
 │           │   orderID = order["orderId"]
 │           │   avgPrice = order["avgPrice"]          // ✅ 真实成交价
 │           │   executedQty = order["executedQty"]    // ✅ 真实成交量
 │           │   commission = order["commission"]      // ✅ 手续费
 │           │   side = order["side"]                  // BUY
 │           ├─ 验证:
 │           │   if avgPrice == 0: return error "invalid avgPrice"
 │           │   if executedQty == 0: return error "executedQty is zero"
 │           └─ database.PnLRecordOpenOrder(traderID, orderInfo)
 │               ├─ INSERT INTO orders (
 │               │     trader_id, order_id, client_order_id,
 │               │     symbol, side, position_side,
 │               │     reduce_only, status,
 │               │     quantity, filled_quantity, avg_price,
 │               │     remaining_quantity,  -- ✅ 初始值 = filled_quantity
 │               │     realized_pnl,        -- 0
 │               │     commission,
 │               │     cycle_number,
 │               │     exchange_response,
 │               │     created_at
 │               │   ) VALUES (?, ?, ?, ...)
 │               └─ remaining_quantity: 核心字段，用于 FIFO 匹配
 │
 └─ 7️⃣ 设置止损止盈
     ├─ if stopLoss > 0:
     │   └─ trader.SetStopLoss(symbol, stopLossPrice)
     │       ├─ Binance: CreateOrder(STOP_MARKET, positionSide=LONG)
     │       ├─ Hyperliquid: CreateOrderRequest(Trigger)
     │       └─ Aster: POST /api/order/stop_loss
     └─ if takeProfit > 0:
         └─ trader.SetTakeProfit(symbol, takeProfitPrice)
```

### 关键数据字段说明

#### orders 表结构

| 字段 | 类型 | 说明 | 重要性 |
|------|------|------|--------|
| `id` | INTEGER | 主键自增 | - |
| `trader_id` | TEXT | 交易员ID | ⭐⭐⭐ |
| `order_id` | TEXT | 交易所订单ID | ⭐⭐⭐ |
| `symbol` | TEXT | 币种 (BTCUSDT) | ⭐⭐⭐ |
| `side` | TEXT | BUY/SELL | ⭐⭐⭐ |
| `position_side` | TEXT | LONG/SHORT | ⭐⭐⭐ |
| `reduce_only` | BOOLEAN | 是否平仓单 | ⭐⭐⭐ |
| `avg_price` | REAL | 成交均价 | ⭐⭐⭐ |
| `filled_quantity` | REAL | 实际成交数量 | ⭐⭐⭐ |
| `remaining_quantity` | REAL | 剩余未平仓数量 | ⭐⭐⭐⭐⭐ (FIFO 核心) |
| `realized_pnl` | REAL | 已实现盈亏 | ⭐⭐⭐ |
| `commission` | REAL | 手续费 (USDT) | ⭐⭐⭐ |
| `cycle_number` | INTEGER | 交易周期编号 | ⭐⭐ |
| `is_synthetic` | BOOLEAN | 是否虚拟订单 | ⭐⭐ |
| `sync_source` | TEXT | 同步来源 | ⭐⭐ |
| `created_at` | DATETIME | 创建时间 | ⭐ |

#### remaining_quantity 字段详解

**作用**: FIFO 匹配算法的核心字段

**生命周期**:
1. **开仓时**: `remaining_quantity = filled_quantity`（全部未平仓）
2. **部分平仓**: `remaining_quantity -= 已平仓数量`
3. **完全平仓**: `remaining_quantity = 0`

**示例**:
```sql
-- 开仓 0.1 BTC
INSERT INTO orders (..., filled_quantity=0.1, remaining_quantity=0.1, reduce_only=0)

-- 部分平仓 0.03 BTC
UPDATE orders SET remaining_quantity = remaining_quantity - 0.03
WHERE id = ? AND reduce_only = 0

-- 查询剩余持仓
SELECT SUM(remaining_quantity) FROM orders
WHERE trader_id = ? AND symbol = 'BTCUSDT' AND position_side = 'LONG' AND reduce_only = 0
-- 结果: 0.07 BTC
```

### 代码位置

- `trader/auto_trader.go:727-813` (开多仓)
- `trader/auto_trader.go:814-900` (开空仓)
- `trader/auto_trader_pnl.go:213-287` (记录订单)
- `trader/binance_futures.go:363-377` (Binance OpenLong)
- `trader/hyperliquid_trader.go:381-432` (Hyperliquid OpenLong)
- `trader/aster_trader.go:459-497` (Aster OpenLong)

---

## 7. 平仓与 PNL 计算

### 平多仓流程 (executeCloseLongWithRecord)

```
executeCloseLongWithRecord(decision)
 ├─ 1️⃣ 执行平仓
 │   └─ order = trader.CloseLong(symbol, quantity)
 │       ├─ Binance: CreateOrder(MARKET, SELL, positionSide=LONG, reduceOnly=true)
 │       ├─ Hyperliquid: CreateOrderRequest(IOC, IsBuy=false, ReduceOnly=true)
 │       └─ Aster: POST /api/order/close
 │
 └─ 2️⃣ 记录平仓订单并计算盈亏
     └─ recordCloseOrderWithPnL(order, symbol, "LONG")
         └─ database.PnLRecordCloseOrder(traderID, closeOrderInfo)
             ├─ ===== 开启事务 =====
             ├─ BEGIN TRANSACTION
             │
             ├─ ===== Step 1: 插入平仓订单 =====
             ├─ INSERT INTO orders (
             │     trader_id, order_id, symbol, side, position_side,
             │     reduce_only=1,  -- ✅ 标记为平仓单
             │     avg_price,      -- 平仓均价
             │     filled_quantity,
             │     remaining_quantity=0,  -- 平仓单没有剩余
             │     realized_pnl=0,        -- 稍后更新
             │     commission,
             │     cycle_number
             │   )
             ├─ closeOrderID = LastInsertId()
             │
             ├─ ===== Step 2: FIFO 匹配开仓订单 =====
             ├─ SELECT id, avg_price, remaining_quantity
             │   FROM orders
             │   WHERE trader_id = ?
             │     AND symbol = ?
             │     AND position_side = ?
             │     AND reduce_only = 0          -- 只匹配开仓单
             │     AND remaining_quantity > 0   -- 还有未平仓数量
             │   ORDER BY created_at ASC        -- ✅ FIFO: 先进先出
             │
             ├─ remainingCloseQty = filled_quantity  -- 需要平仓的总量
             ├─ totalPnL = 0
             ├─ totalCommission = 0
             │
             ├─ for each openOrder:
             │   ├─ matchQty = min(remainingCloseQty, openOrder.remaining_quantity)
             │   │
             │   ├─ ===== 计算盈亏 =====
             │   ├─ if position_side == "LONG":
             │   │   └─ pnl = (closePrice - entryPrice) × matchQty
             │   │       例: (51000 - 50000) × 0.03 = 30 USDT
             │   └─ if position_side == "SHORT":
             │       └─ pnl = (entryPrice - closePrice) × matchQty
             │           例: (50000 - 49000) × 0.03 = 30 USDT
             │   │
             │   ├─ totalPnL += pnl
             │   │
             │   ├─ ===== 更新开仓订单的 remaining_quantity =====
             │   ├─ UPDATE orders
             │   │   SET remaining_quantity = remaining_quantity - matchQty,
             │   │       realized_pnl = realized_pnl + pnl
             │   │   WHERE id = openOrder.id
             │   │
             │   ├─ remainingCloseQty -= matchQty
             │   │
             │   └─ if remainingCloseQty == 0:
             │       └─ break  -- 平仓量已全部匹配完
             │
             ├─ ===== Step 3: 扣除手续费 =====
             ├─ totalCommission = closeOrder.commission + SUM(openOrder.commission)
             ├─ netPnL = totalPnL - totalCommission
             │
             ├─ ===== Step 4: 更新平仓订单的 realized_pnl =====
             ├─ UPDATE orders
             │   SET realized_pnl = netPnL
             │   WHERE id = closeOrderID
             │
             ├─ ===== 提交事务 =====
             ├─ COMMIT
             │
             └─ 返回 (realizedPnL=netPnL, totalCommission)
```

### FIFO 匹配示例

#### 场景: 分批开仓后一次性平仓

```
时间线:
10:00 - 开多仓 0.05 BTC @ 50000 USDT (订单A)
10:30 - 开多仓 0.03 BTC @ 51000 USDT (订单B)
11:00 - 开多仓 0.02 BTC @ 52000 USDT (订单C)
11:30 - 平多仓 0.08 BTC @ 53000 USDT (平仓订单)

FIFO 匹配过程:
1. 匹配订单A (最早):
   - matchQty = min(0.08, 0.05) = 0.05
   - pnl = (53000 - 50000) × 0.05 = 150 USDT
   - 订单A.remaining_quantity = 0.05 - 0.05 = 0 (完全平仓)
   - remainingCloseQty = 0.08 - 0.05 = 0.03

2. 匹配订单B (次早):
   - matchQty = min(0.03, 0.03) = 0.03
   - pnl = (53000 - 51000) × 0.03 = 60 USDT
   - 订单B.remaining_quantity = 0.03 - 0.03 = 0 (完全平仓)
   - remainingCloseQty = 0.03 - 0.03 = 0 (匹配完成)

3. 订单C 不匹配（还有剩余持仓）

总盈亏 = 150 + 60 = 210 USDT
扣除手续费 (假设0.04%):
  - 开仓手续费: (50000×0.05 + 51000×0.03 + 52000×0.02) × 0.0004 = 1.66 USDT
  - 平仓手续费: 53000×0.08 × 0.0004 = 1.70 USDT
  - 总手续费: 3.36 USDT
净盈亏 = 210 - 3.36 = 206.64 USDT
```

### 内存状态更新

```go
// 更新内存中的 PNL 统计
at.pnlMutex.Lock()
at.totalRealizedPnL += realizedPnL  // 累加已实现盈亏
at.totalCommission += totalCommission  // 累加手续费
at.pnlMutex.Unlock()

log.Printf("✓ [%s] 累计盈亏: %.2f (本次: %.2f, 手续费: %.2f)",
    at.name, at.totalRealizedPnL, realizedPnL, totalCommission)
```

### 代码位置

- `trader/auto_trader.go:901-934` (平多仓)
- `trader/auto_trader.go:935-968` (平空仓)
- `trader/auto_trader_pnl.go:290-355` (recordCloseOrderWithPnL)
- `config/database.go:1531-1699` (PnLRecordCloseOrder - FIFO 匹配算法)

---

## 8. 回撤监控

### 流程图

```
startDrawdownMonitor()
 └─ 启动 goroutine (后台运行)
     └─ ticker: 每 1 分钟触发
         └─ checkPositionDrawdown()
             ├─ 获取所有持仓
             │   └─ trader.GetPositions()
             │
             └─ for each position:
                 ├─ 1️⃣ 计算当前盈亏百分比
                 │   └─ if side == "long":
                 │       └─ pnlPct = ((markPrice - entryPrice) / entryPrice) × leverage × 100
                 │       例: ((51000 - 50000) / 50000) × 10 = 20%
                 │   └─ if side == "short":
                 │       └─ pnlPct = ((entryPrice - markPrice) / entryPrice) × leverage × 100
                 │
                 ├─ 2️⃣ 获取/更新峰值收益
                 │   ├─ posKey = symbol + "_" + side  (例: "BTCUSDT_long")
                 │   ├─ peakPnLPct = peakPnLCache[posKey]
                 │   └─ if currentPnLPct > peakPnLPct:
                 │       └─ UpdatePeakPnL(symbol, side, currentPnLPct)
                 │
                 ├─ 3️⃣ 计算回撤幅度
                 │   └─ if peakPnLPct > 0 && currentPnLPct < peakPnLPct:
                 │       └─ drawdownPct = ((peakPnLPct - currentPnLPct) / peakPnLPct) × 100
                 │       例: 峰值25%，当前15%
                 │           回撤 = ((25 - 15) / 25) × 100 = 40%
                 │
                 └─ 4️⃣ 检查平仓条件
                     └─ if currentPnLPct > 5% && drawdownPct >= 40%:
                         ├─ 日志: "🚨 触发回撤平仓条件"
                         ├─ emergencyClosePosition(symbol, side)
                         │   ├─ if side == "long":
                         │   │   └─ trader.CloseLong(symbol, 0)  // 0 = 全平
                         │   └─ if side == "short":
                         │       └─ trader.CloseShort(symbol, 0)
                         │   └─ recordCloseOrderWithPnL()
                         └─ ClearPeakPnLCache(symbol, side)  // 清理缓存
```

### 回撤条件说明

#### 为什么是 "收益 > 5% && 回撤 >= 40%"？

1. **收益 > 5%**: 确保有足够的盈利空间才触发保护
   - 避免小幅盈利时被频繁平仓
   - 给予策略足够的波动空间

2. **回撤 >= 40%**: 从峰值回撤 40% 说明趋势可能反转
   - 例: 峰值 25% → 当前 15%（回撤 40%）
   - 例: 峰值 10% → 当前 6%（回撤 40%）

#### 回撤示例

```
时间线:
10:00 - 开多仓 BTC @ 50000，盈亏 0%
10:15 - 价格涨到 51000，盈亏 +10% (杠杆5x，实际2%)
      → 更新 peakPnLCache["BTCUSDT_long"] = 10%
10:30 - 价格涨到 52500，盈亏 +25%
      → 更新 peakPnLCache["BTCUSDT_long"] = 25% (新峰值)
10:45 - 价格回落到 51500，盈亏 +15%
      → 回撤 = (25 - 15) / 25 = 40%
      → ✅ 触发条件: 收益15% > 5% && 回撤40% >= 40%
      → 🚨 执行紧急平仓
```

### 峰值缓存管理

```go
// 更新峰值（只增不减）
func (at *AutoTrader) UpdatePeakPnL(symbol, side string, currentPnLPct float64) {
    posKey := symbol + "_" + side
    at.peakPnLCacheMutex.Lock()
    defer at.peakPnLCacheMutex.Unlock()

    if current, exists := at.peakPnLCache[posKey]; !exists || currentPnLPct > current {
        at.peakPnLCache[posKey] = currentPnLPct
        log.Printf("📈 更新峰值: %s = %.2f%%", posKey, currentPnLPct)
    }
}

// 清理缓存（平仓后）
func (at *AutoTrader) ClearPeakPnLCache(symbol, side string) {
    posKey := symbol + "_" + side
    at.peakPnLCacheMutex.Lock()
    delete(at.peakPnLCache, posKey)
    at.peakPnLCacheMutex.Unlock()
    log.Printf("🧹 清理峰值缓存: %s", posKey)
}
```

### 并发安全

- 回撤监控运行在独立 goroutine
- 与主循环（AI 决策）并行运行
- 使用 `sync.RWMutex` 保护缓存读写
- 使用 `stopMonitorCh` 通道优雅停止

### 代码位置

- `trader/auto_trader.go:1534-1554` (startDrawdownMonitor)
- `trader/auto_trader.go:1557-1630` (checkPositionDrawdown)
- `trader/auto_trader.go:1633-1653` (emergencyClosePosition)
- `trader/auto_trader.go:1668-1692` (UpdatePeakPnL, ClearPeakPnLCache)

---

## 9. 停止流程

### 流程图

```
main() 收到 SIGTERM/SIGINT (Ctrl+C)
 │
 ├─ 步骤 1: 停止所有交易员
 │   └─ traderManager.StopAll()
 │       └─ for each trader:
 │           └─ trader.Stop()
 │               ├─ isRunning = false
 │               ├─ close(stopMonitorCh)  -- 通知 goroutine 停止
 │               │   ├─ 主循环收到信号: case <-stopMonitorCh: return
 │               │   └─ 回撤监控收到信号: case <-stopMonitorCh: return
 │               └─ monitorWg.Wait()  -- 等待所有 goroutine 结束
 │
 ├─ 步骤 2: 关闭 API 服务器
 │   └─ apiServer.Shutdown(ctx)
 │       ├─ 停止接受新请求
 │       ├─ 等待现有请求完成（超时5秒）
 │       └─ 关闭所有连接
 │
 ├─ 步骤 3: 关闭行情监控
 │   └─ market.WSMonitor.Stop()
 │       └─ 关闭 WebSocket 连接
 │
 ├─ 步骤 4: 关闭数据库连接
 │   └─ database.Close()
 │       ├─ 刷新未写入的缓冲
 │       └─ 关闭 SQLite 连接
 │
 └─ 步骤 5: 退出进程
     └─ os.Exit(0)
```

### 优雅停止机制

#### 1. 信号捕获

```go
sigChan := make(chan os.Signal, 1)
signal.Notify(sigChan, os.Interrupt, syscall.SIGTERM)

// 阻塞等待信号
<-sigChan
log.Println("📛 收到退出信号，正在优雅关闭...")
```

#### 2. goroutine 协调

使用 `sync.WaitGroup` 确保所有 goroutine 正常退出：

```go
// 启动时
at.monitorWg.Add(1)
go func() {
    defer at.monitorWg.Done()
    // 主循环逻辑
}()

// 停止时
at.isRunning = false
close(at.stopMonitorCh)  // 触发退出
at.monitorWg.Wait()      // 等待完成
```

#### 3. 通道关闭顺序

```
1. close(stopMonitorCh)      -- 触发信号
2. 主循环退出               -- case <-stopMonitorCh
3. 回撤监控退出             -- case <-stopMonitorCh
4. monitorWg.Done()         -- 计数器减1
5. monitorWg.Wait() 返回    -- 所有 goroutine 已结束
```

### 停止时机选择

#### 安全停止点

1. **主循环的 select 语句**:
   ```go
   select {
   case <-ticker.C:
       // 正在执行 AI 决策
   case <-at.stopMonitorCh:
       return  // 安全退出点
   }
   ```

2. **回撤监控的 ticker**:
   ```go
   select {
   case <-ticker.C:
       // 正在检查回撤
   case <-at.stopMonitorCh:
       return  // 安全退出点
   }
   ```

#### 不安全的停止点

- ❌ 订单执行过程中（可能导致订单未记录）
- ❌ 数据库事务中（可能导致数据不一致）
- ❌ API 调用过程中（可能导致连接泄漏）

### 数据持久化

**系统停止前，所有关键数据已写入数据库：**

- ✅ PNL 状态（totalRealizedPnL, totalCommission）
- ✅ 订单记录（orders 表）
- ✅ 持仓状态（通过 orders 表的 remaining_quantity 计算）
- ✅ 决策日志（decision_logs/{trader_id}/*.json）

**重启后自动恢复：**

```go
// trader.Run() 中
restorePNLFromDB()         // 恢复盈亏状态
syncPositionsRuntime()     // 同步持仓
verifyAccountBalance()     // 验证账户
// 继续正常运行
```

### 代码位置

- `main.go:352-375` (信号捕获 & 停止流程)
- `trader/auto_trader.go:353-361` (Stop 方法)
- `manager/trader_manager.go:445-453` (StopAll 方法)

---

## 10. 数据流架构

### 系统架构图

```
┌─────────────────────────────────────────────────────────────┐
│                      Main Process                           │
│                      (main.go)                              │
└───────────┬─────────────┬─────────────┬─────────────────────┘
            │             │             │
    ┌───────▼──────┐ ┌───▼─────┐  ┌───▼──────────┐
    │   Database   │ │   API   │  │  WS Monitor  │
    │   (SQLite)   │ │  Server │  │  (Market)    │
    │              │ │         │  │              │
    │ • Config     │ │ • REST  │  │ • Binance   │
    │ • Orders     │ │ • WebUI │  │ • Real-time │
    │ • Traders    │ │ • JWT   │  │   Prices    │
    └───────┬──────┘ └───┬─────┘  └──────────────┘
            │            │
    ┌───────▼────────────▼──────────────┐
    │       TraderManager                │
    │   (管理多个 Trader 实例)           │
    │   • 并发安全 (sync.RWMutex)        │
    │   • 统一调度                       │
    └───────┬────────────────────────────┘
            │
    ┌───────┴────────┬────────┬────────┐
    │                │        │        │
┌───▼────┐   ┌──────▼───┐ ┌──▼────┐ ┌─▼─────┐
│Trader1 │   │ Trader2  │ │Trader3│ │ ...   │
│(独立)  │   │ (独立)   │ │(独立) │ │       │
└───┬────┘   └──────┬───┘ └──┬────┘ └───────┘
    │               │        │
    每个 Trader 独立运行:
    │
    ├─ Run() 主循环 (goroutine)
    │   ├─ PNL 恢复
    │   ├─ 仓位同步
    │   ├─ 账户对账
    │   └─ runCycle() 定时执行 (每3分钟)
    │       ├─ buildTradingContext()
    │       ├─ AI 决策 (DeepSeek/Qwen)
    │       └─ 执行订单
    │           ├─ 开仓: OpenLong/OpenShort
    │           ├─ 平仓: CloseLong/CloseShort
    │           └─ 调整: UpdateStopLoss/TakeProfit
    │
    └─ 回撤监控 (goroutine)
        └─ checkPositionDrawdown() 每1分钟
            ├─ 计算回撤
            └─ 紧急平仓
```

### 数据流向

```
1️⃣ 配置加载流:
   config.json → Database → TraderManager → AutoTrader

2️⃣ 行情数据流:
   Exchange WebSocket → Market Module → AutoTrader.buildTradingContext()

3️⃣ AI 决策流:
   Context → AI API (DeepSeek/Qwen) → Decision List → Execute

4️⃣ 订单执行流:
   Decision → Trader Interface → Exchange API → Order Response

5️⃣ PNL 记录流:
   Order Response → recordOrder() → Database (orders 表)

6️⃣ 平仓匹配流:
   Close Order → FIFO Match → Update Orders → PNL Calculation

7️⃣ 状态查询流:
   API Request → TraderManager → AutoTrader.GetStatus() → JSON Response
```

### 并发模型

```
每个 Trader 独立运行，互不干扰:

Trader1:
  ├─ goroutine-1: 主循环 (AI 决策 + 执行)
  └─ goroutine-2: 回撤监控

Trader2:
  ├─ goroutine-3: 主循环
  └─ goroutine-4: 回撤监控

Trader3:
  ├─ goroutine-5: 主循环
  └─ goroutine-6: 回撤监控

共享资源:
  • Database (SQLite 内置锁)
  • Market Data (只读，线程安全)
  • API Server (每个请求独立 goroutine)
```

### 代码位置

- `main.go:266-349` (架构初始化)
- `manager/trader_manager.go:24-39` (TraderManager 结构)
- `trader/auto_trader.go:115-151` (AutoTrader 结构)

---

## 11. 关键时间节点

### 时间表

| 阶段 | 触发时机 | 频率 | 主要动作 | 代码位置 |
|------|---------|------|---------|---------|
| **系统启动** | 进程启动 | 一次 | 初始化数据库、加载配置、创建 Trader | main.go:153 |
| **Trader 启动** | Run() 调用 | 一次 | PNL 恢复、仓位同步、账户对账 | auto_trader.go:288 |
| **AI 决策周期** | Ticker | 每 3 分钟 | 构建 Context → AI 分析 → 执行订单 | auto_trader.go:364 |
| **回撤检查** | Ticker | 每 1 分钟 | 计算回撤、触发保护性平仓 | auto_trader.go:1557 |
| **日盈亏重置** | 时间判断 | 每 24 小时 | dailyPnL = 0, lastResetTime = now | auto_trader.go:388 |
| **余额同步** | 可选 | 每 N 小时 | 同步交易所余额到数据库 | - |
| **系统停止** | SIGTERM/SIGINT | 一次 | 优雅关闭所有 goroutine、保存状态 | main.go:359 |

### 时间线示例

```
00:00:00 - 系统启动
00:00:01 - 数据库初始化完成
00:00:02 - 加载 3 个 Trader 配置
00:00:03 - Trader1 启动: PNL 恢复 (累计 +150 USDT)
00:00:04 - Trader1: 仓位同步 (发现 1 个孤儿仓位)
00:00:05 - Trader1: 账户对账通过
00:00:06 - Trader1: 启动回撤监控 goroutine
00:00:07 - Trader1: 主循环开始运行
00:00:08 - Trader1: 首次 AI 决策 (#1)
         ├─ 构建 Context (5 个候选币种)
         ├─ 调用 DeepSeek API (耗时 2s)
         └─ 执行 2 个决策: open_long BTCUSDT, close_short ETHUSDT

00:03:00 - Trader1: 第 2 次 AI 决策 (#2)
00:06:00 - Trader1: 第 3 次 AI 决策 (#3)
00:07:00 - Trader1: 回撤监控触发 (BTC 盈利 +15%, 回撤 45%)
         └─ 🚨 紧急平仓 BTCUSDT_long

00:09:00 - Trader1: 第 4 次 AI 决策 (#4)
...

08:00:00 - Trader1: 日盈亏重置 (昨日 +230 USDT)
         └─ dailyPnL = 0

23:59:50 - 收到 SIGTERM 信号 (Ctrl+C)
23:59:51 - 停止所有 Trader
         ├─ Trader1: 主循环退出
         └─ Trader1: 回撤监控退出
23:59:52 - 关闭 API 服务器
23:59:53 - 关闭数据库连接
23:59:54 - 进程退出
```

### 超时和重试策略

| 操作 | 超时时间 | 重试次数 | 重试间隔 |
|------|---------|---------|---------|
| AI API 调用 | 30 秒 | 1 | - |
| 交易所 API | 10 秒 | 3 | 1s, 2s, 4s (指数退避) |
| 数据库写入 | - | 3 | 1s, 2s, 4s |
| WebSocket 连接 | 5 秒 | 无限 | 5s |

### 代码位置

- `trader/auto_trader.go:329` (主循环 Ticker)
- `trader/auto_trader.go:1539` (回撤监控 Ticker)
- `trader/auto_trader.go:388-392` (日盈亏重置)
- `trader/auto_trader_pnl.go:215-224` (重试机制)

---

## 12. 核心数据结构

### AutoTrader 结构体

```go
type AutoTrader struct {
    // ===== 基础信息 =====
    id                    string                   // Trader 唯一标识 (例: "trader_001")
    name                  string                   // Trader 显示名称 (例: "BTC Hunter")
    aiModel               string                   // AI 模型名称 (deepseek/qwen/custom)
    exchange              string                   // 交易平台 (binance/hyperliquid/aster)
    config                AutoTraderConfig         // 配置对象
    trader                Trader                   // 交易接口 (多态)
    database              *database.Database       // 数据库连接
    userID                string                   // 所属用户ID

    // ===== AI 相关 =====
    mcpClient             *mcp.Client              // AI 客户端
    decisionLogger        *logger.DecisionLogger   // 决策日志
    customPrompt          string                   // 自定义策略提示词
    overrideBasePrompt    bool                     // 是否覆盖基础提示词
    systemPromptTemplate  string                   // 系统提示词模板 (adaptive/aggressive)

    // ===== 币种配置 =====
    defaultCoins          []string                 // 默认币种列表
    tradingCoins          []string                 // 实际交易币种

    // ===== 账户状态 =====
    initialBalance        float64                  // 初始余额 (用于计算盈亏)
    dailyPnL              float64                  // 当日盈亏
    lastResetTime         time.Time                // 上次重置时间
    lastBalanceSyncTime   time.Time                // 上次余额同步时间

    // ===== 运行状态 =====
    isRunning             bool                     // 是否运行中
    startTime             time.Time                // 启动时间
    callCount             int                      // AI 调用次数
    stopUntil             time.Time                // 风控暂停截止时间
    stopMonitorCh         chan struct{}            // 停止信号通道
    monitorWg             sync.WaitGroup           // goroutine 等待组

    // ===== 持仓跟踪 =====
    positionFirstSeenTime map[string]int64         // 持仓首次出现时间 (symbol_side -> timestamp)
    peakPnLCache          map[string]float64       // 峰值收益缓存 (symbol_side -> pnlPct)
    peakPnLCacheMutex     sync.RWMutex             // 缓存读写锁

    // ===== PNL 系统 =====
    totalRealizedPnL      float64                  // 累计已实现盈亏 (从数据库恢复)
    totalCommission       float64                  // 累计手续费
    cycleNumber           int                      // 当前交易周期编号
    pnlMutex              sync.RWMutex             // PNL 数据读写锁
}
```

### Order 订单结构体

```go
type Order struct {
    ID                int64   `json:"id"`                // 主键 (自增)
    TraderID          string  `json:"trader_id"`         // 交易员ID
    OrderID           string  `json:"order_id"`          // 交易所订单ID
    ClientOrderID     string  `json:"client_order_id"`   // 客户端订单ID
    Symbol            string  `json:"symbol"`            // 币种 (BTCUSDT)
    Side              string  `json:"side"`              // BUY/SELL
    PositionSide      string  `json:"position_side"`     // LONG/SHORT
    ReduceOnly        bool    `json:"reduce_only"`       // 是否平仓单 (核心标识)
    Status            string  `json:"status"`            // FILLED/CANCELED
    Quantity          float64 `json:"quantity"`          // 委托数量
    FilledQuantity    float64 `json:"filled_quantity"`   // 实际成交数量
    AvgPrice          float64 `json:"avg_price"`         // 成交均价 (核心字段)
    RemainingQuantity float64 `json:"remaining_quantity"` // 剩余未平仓数量 (FIFO 核心)
    RealizedPnL       float64 `json:"realized_pnl"`      // 已实现盈亏
    Commission        float64 `json:"commission"`        // 手续费 (USDT)
    IsSynthetic       bool    `json:"is_synthetic"`      // 是否虚拟订单
    SyncSource        string  `json:"sync_source"`       // NORMAL/MANUAL_IMPORT
    CycleNumber       int     `json:"cycle_number"`      // 所属交易周期
    CreatedAt         string  `json:"created_at"`        // 创建时间
    UpdatedAt         string  `json:"updated_at"`        // 更新时间
}
```

### Position 持仓结构体

```go
type Position struct {
    Symbol     string  `json:"symbol"`       // 币种
    Side       string  `json:"side"`         // LONG/SHORT
    Quantity   float64 `json:"quantity"`     // 持仓数量 (绝对值)
    EntryPrice float64 `json:"entry_price"`  // 成本价
}
```

### Context 交易上下文

```go
type Context struct {
    CurrentTime     string                   // 当前时间 "2025-01-15 10:30:00"
    RuntimeMinutes  int                      // 运行时长（分钟）
    CallCount       int                      // AI 调用次数
    BTCETHLeverage  int                      // BTC/ETH 杠杆倍数
    AltcoinLeverage int                      // 山寨币杠杆倍数
    Account         AccountInfo              // 账户信息
    Positions       []PositionInfo           // 持仓列表
    CandidateCoins  []CandidateCoin          // 候选币种
    Performance     *PerformanceAnalysis     // 历史表现
}
```

### 数据生命周期

```
AutoTrader 实例:
  NewAutoTrader() → Run() → [运行中] → Stop() → GC 回收
                     ↓
                PNL 字段初始化:
                  ├─ restorePNLFromDB() → totalRealizedPnL, totalCommission
                  └─ syncPositionsRuntime() → positionFirstSeenTime

每个交易周期 (runCycle):
  Context 创建 → AI 决策 → 执行订单 → 记录到 DB → 更新内存 PNL
                                     ↓
                            orders 表 FIFO 匹配
                                     ↓
                            totalRealizedPnL += pnl

系统停止:
  Stop() → 保存状态到 DB → 关闭连接 → 退出进程
          ↓
    orders 表持久化 (重启后恢复)
```

### 代码位置

- `trader/auto_trader.go:115-151` (AutoTrader 结构体)
- `trader/auto_trader.go:22-51` (Order, Position 结构体)
- `decision/context.go` (Context 结构体)

---

## 附录: 常见问题

### Q1: 如何查看某个 Trader 的历史盈亏？

```sql
-- 查询累计盈亏
SELECT SUM(realized_pnl) AS total_pnl, SUM(commission) AS total_fee
FROM orders
WHERE trader_id = 'trader_001';

-- 查询每日盈亏
SELECT DATE(created_at) AS date,
       SUM(realized_pnl) AS daily_pnl,
       COUNT(*) AS order_count
FROM orders
WHERE trader_id = 'trader_001' AND reduce_only = 1
GROUP BY DATE(created_at)
ORDER BY date DESC;
```

### Q2: 如何手动接管一个孤儿仓位？

系统会在启动时自动检测并创建虚拟订单，无需手动操作。如果需要手动接管：

1. 确保交易所有实际持仓
2. 重启 Trader（会触发 `syncPositionsRuntime()`）
3. 检查日志: "发现 N 个孤儿仓位"
4. 系统自动创建虚拟订单（`is_synthetic = 1`）

### Q3: 如何调整 AI 决策频率？

修改配置中的 `ScanInterval`:

```go
config := AutoTraderConfig{
    ScanInterval: 3 * time.Minute,  // 默认 3 分钟
    // 改为 5 分钟:
    // ScanInterval: 5 * time.Minute,
}
```

### Q4: 如何禁用回撤监控？

注释掉 `Run()` 中的启动代码:

```go
// at.startDrawdownMonitor()  // 禁用回撤监控
```

### Q5: 如何查看 FIFO 匹配详情？

查看数据库日志（在 `PnLRecordCloseOrder` 中有详细打印）:

```
[trader_001] 🔍 FIFO 平仓: BTCUSDT LONG, 需平仓: 0.08
  匹配订单#1: entry=50000, remaining=0.05
    → 匹配数量: 0.05, PnL: 150.00 USDT
  匹配订单#2: entry=51000, remaining=0.03
    → 匹配数量: 0.03, PnL: 60.00 USDT
  ✓ 平仓完成, 总盈亏: 206.64 USDT (扣除手续费 3.36)
```

---

## 版本历史

- **v1.0** (2025-01-15): 初始版本，完整梳理 Trader 生命周期
- **v1.1** (TBD): 计划添加多账户并发管理、风控策略扩展

---

**文档维护**: 请在代码变更时同步更新此文档

**相关文档**:
- [PNL 系统设计](./pnl_system_design.md)
- [AI 决策系统](./ai_decision_system.md)
- [交易所接口规范](./exchange_interface_spec.md)
