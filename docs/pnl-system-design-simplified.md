# 简化版PNL统计系统设计

> **版本**: v2.2 (推荐方案)
> **作者**: Claude
> **日期**: 2025-11-11
> **状态**: ✅ **最终方案** - 统一处理,最大简化
> **原则**: 最小改动,最大效果,统一逻辑
> **核心**: 虚拟订单机制 + 统一处理

---

## 📋 文档说明

### 版本历史
- **v1.0 (已废弃)**: [pnl-system-design.md](./pnl-system-design.md) - 完整版设计(3个新表)
- **v2.0 (已废弃)**: 简化版设计初稿 - 存在关键缺陷
- **v2.1 (已废弃)**: 修复关键缺陷 - 但逻辑复杂
- **v2.2 (当前)**: 统一处理方案 - 最终简化版 ✅

### 设计决策
| 考虑因素 | v1.0 完整版 | v2.1 修复版 | v2.2 统一版(推荐)|
|---------|------------|------------|------------------|
| 新增表数量 | 3个 | 1个 | **1个** ✅ |
| 实施时间 | 3天 | 2-3天 | **2天** ✅ |
| 代码复杂度 | 高 | 中 | **低** ✅ |
| 维护成本 | 高 | 中 | **低** ✅ |
| 功能完整性 | 100% | 95% | **95%** ✅ |
| 数据正确性 | 高 | 高 | **高** ✅ |
| 逻辑统一性 | 中 | 中 | **高** ✅ |

**v2.2 核心改进**: 通过"虚拟订单机制",所有仓位统一处理,代码逻辑大幅简化。

---

## 🎯 核心设计理念

### 设计目标
1. ✅ 准确统计已实现盈亏和未实现盈亏
2. ✅ 支持系统重启后状态恢复
3. ✅ 支持部分平仓和多次平仓
4. ✅ **统一处理所有仓位** (核心创新)
5. ✅ 数据库事务保证一致性
6. ✅ 完善的错误处理和告警机制

### 🌟 核心创新：统一处理原则

```
核心思想：
通过"虚拟订单机制",让所有仓位(无论来源)在 orders 表中都有记录。
后续操作完全不区分仓位来源,使用统一的代码路径。

┌─────────────────────────────────┐
│   启动时的仓位来源(3种)          │
├─────────────────────────────────┤
│ 1. AI开仓 → orders表已有记录     │
│ 2. 遗留仓位 → orders表已有记录   │
│ 3. 手动开仓 → 创建虚拟订单 ✅    │
└─────────────────────────────────┘
              ↓
    【仓位同步:补齐虚拟订单】
              ↓
┌─────────────────────────────────┐
│   orders表统一视图               │
├─────────────────────────────────┤
│ 所有仓位都有完整记录:            │
│ - avg_price (成本价)            │
│ - remaining_quantity (剩余数量) │
└─────────────────────────────────┘
              ↓
    【后续操作完全统一】
              ↓
┌─────────────────────────────────┐
│ - 平仓逻辑:相同                  │
│ - 盈亏计算:相同                  │
│ - 止盈止损:相同                  │
│ - 部分平仓:相同                  │
│ → 不需要 if (is_synthetic) ✅   │
└─────────────────────────────────┘
```

**优势**:
- ✅ 代码极简:后续操作无需区分来源
- ✅ 易于维护:单一代码路径
- ✅ 不易出错:减少if分支
- ✅ 易于测试:逻辑统一

---

## 🎯 设计思路

### 核心公式
```
Equity = InitialBalance + RealizedPnL + UnrealizedPnL

其中:
- InitialBalance: 系统接管时的 walletBalance (常量)
- RealizedPnL: 从 orders 表累加计算 (所有订单,含虚拟订单)
- UnrealizedPnL: 从交易所API实时获取
```

### 🔑 InitialBalance 的设定(关键)

**核心原则**: `initial_balance` **始终等于系统接管那一刻的 walletBalance**

#### 为什么这样设计?

```
InitialBalance 代表"AI系统开始管理时的账户状态"
- 它是Equity计算的基准点
- 它反映了账户的历史累积结果(包括之前所有的盈亏、充值、提现)
- 从这一刻开始,所有的PnL计算都相对于这个基准
```

#### 创建 Trader 时如何设置?

##### 场景1: 创建时无仓位

```go
func (at *AutoTrader) setInitialBalance() error {
    // 1. 从交易所获取当前余额
    balance, err := at.trader.GetBalance()
    if err != nil {
        return err
    }

    walletBalance := getFloat64Field(balance, "totalWalletBalance")

    // 2. 设置 initial_balance = walletBalance
    //    此时 realizedPnL = 0, unrealizedPnL = 0
    _, err = at.db.Exec(`
        UPDATE traders
        SET initial_balance = ?,
            original_deposit = ?,  -- 可选,等于 initial_balance
            total_realized_pnl = 0,
            total_commission = 0
        WHERE id = ?
    `, walletBalance, walletBalance, at.id)

    if err != nil {
        return err
    }

    at.initialBalance = walletBalance
    log.Printf("✓ 初始化: initial_balance = %.2f (无仓位)", walletBalance)

    return nil
}
```

**结果**:
```
Equity = InitialBalance + 0 + 0 = walletBalance ✅
```

##### 场景2: 创建时有仓位

```go
func (at *AutoTrader) handleOrphanPositionsOnCreation(orphans []Position) error {
    tx, err := at.db.Begin()
    if err != nil {
        return err
    }
    defer tx.Rollback()

    // 1. 为所有孤儿仓位创建虚拟订单
    for _, orphan := range orphans {
        if err := at.createSyntheticOrderInTx(tx, orphan, "EXCHANGE_SYNC"); err != nil {
            return err
        }
    }

    // 2. 从交易所获取当前余额
    balance, err := at.trader.GetBalance()
    if err != nil {
        return err
    }

    walletBalance := getFloat64Field(balance, "totalWalletBalance")
    unrealizedPnL := getFloat64Field(balance, "totalUnrealizedProfit")

    // 3. ✅ 关键: initial_balance = walletBalance
    //    不是 walletBalance - unrealizedPnL
    //    因为我们的公式是: Equity = InitialBalance + RealizedPnL + UnrealizedPnL
    _, err = tx.Exec(`
        UPDATE traders
        SET initial_balance = ?,
            total_realized_pnl = 0,   -- 创建时刻,还没有任何平仓
            total_commission = 0
        WHERE id = ?
    `, walletBalance, at.id)

    if err != nil {
        return err
    }

    if err = tx.Commit(); err != nil {
        return err
    }

    at.initialBalance = walletBalance

    log.Printf("✓ 初始化: initial_balance = %.2f (有仓位)", walletBalance)
    log.Printf("   当前未实现盈亏 = %.2f", unrealizedPnL)
    log.Printf("   当前净值 = %.2f + 0 + %.2f = %.2f",
        walletBalance, unrealizedPnL, walletBalance + unrealizedPnL)

    return nil
}
```

**示例**:
```
假设创建时:
- walletBalance = 95 USDT
- 有1个LONG仓位: BTC 0.001, entryPrice=90000, 当前价格=95000
- unrealizedPnL = (95000 - 90000) * 0.001 = +5 USDT

那么:
initial_balance = 95 USDT ← 关键!不是90
realizedPnL = 0
unrealizedPnL = +5 USDT

Equity = 95 + 0 + 5 = 100 USDT ✅
```

#### 为什么不是 `initial_balance = walletBalance - unrealizedPnL`?

❌ **错误理解**:
```
有人可能认为应该"扣除"未实现盈亏,设置为:
initial_balance = walletBalance - unrealizedPnL = 95 - 5 = 90
```

✅ **正确理解**:
```
我们的公式是:
  Equity = InitialBalance + RealizedPnL + UnrealizedPnL

如果设置 initial_balance = 90,那么:
  Equity = 90 + 0 + 5 = 95 (错误!应该是100)

正确做法:
  initial_balance = 95 (就是当前的 walletBalance)
  Equity = 95 + 0 + 5 = 100 ✅
```

#### InitialBalance vs OriginalDeposit

| 字段 | 含义 | 使用场景 | 示例 |
|------|------|---------|------|
| `initial_balance` | 系统接管时的余额 | **Equity计算** | 创建时=95, 重启后不变 |
| `original_deposit` | 用户原始充值金额 | 用户总收益率展示 | 用户充值=100 |

**示例**:
```
用户充值 100 USDT
手动交易亏损 5 USDT (walletBalance = 95)
此时创建 Trader

设置:
  initial_balance = 95 ← 系统接管时的状态
  original_deposit = 100 ← 用户原始充值(可选,用于展示)

AI 运行一段时间后,赚了10 USDT:
  Equity = 95 + 10 + 0 = 105 USDT

展示给用户:
  - 系统管理收益率 = 10 / 95 = 10.53% (从接管时起算)
  - 用户总收益率 = (105 - 100) / 100 = 5% (从充值起算)
```

#### 重启时如何处理?

```go
func (at *AutoTrader) restoreFromDB() error {
    // ✅ 从数据库恢复 - initial_balance 永不改变
    err := at.db.QueryRow(`
        SELECT initial_balance, original_deposit, total_realized_pnl, total_commission
        FROM traders WHERE id = ?
    `, at.id).Scan(&at.initialBalance, &at.originalDeposit, &at.totalRealizedPnL, &at.totalCommission)

    // initial_balance 在整个 trader 生命周期中保持不变
    // 它是计算 Equity 的固定基准

    return err
}
```

**关键**: 重启时,`initial_balance` **不会重新计算**,而是从数据库读取原值。

#### 总结

```
┌────────────────────────────────────────────────────┐
│ InitialBalance 设定规则                             │
├────────────────────────────────────────────────────┤
│                                                    │
│ 1. 创建时刻:                                        │
│    initial_balance = 当前的 walletBalance          │
│    (无论有没有仓位)                                 │
│                                                    │
│ 2. 整个生命周期:                                    │
│    initial_balance 永不改变                        │
│    它是 Equity 计算的固定基准                       │
│                                                    │
│ 3. 公式保证:                                        │
│    Equity = InitialBalance + RealizedPnL + UnrealizedPnL │
│    始终成立 ✅                                      │
│                                                    │
└────────────────────────────────────────────────────┘
```

### 数据流
```
1. 创建/启动 trader → 执行仓位同步
2. 仓位同步 → 发现孤儿仓位 → 创建虚拟订单 + 发送告警
3. AI开仓 → 记录到 orders 表,remaining_quantity = quantity
4. AI平仓 → FIFO匹配所有订单(含虚拟订单),更新 remaining_quantity
5. 查询净值 → 累加 orders.realized_pnl + 交易所 unrealized_pnl
```

---

## 📊 数据库设计

### 1. 修改现有 `traders` 表(添加字段)

```sql
ALTER TABLE traders
ADD COLUMN initial_balance DECIMAL(20, 8) NOT NULL COMMENT '系统接管时的钱包余额(Equity计算基准)',
ADD COLUMN original_deposit DECIMAL(20, 8) DEFAULT NULL COMMENT '用户原始充值金额(可选,用于展示真实收益率)',
ADD COLUMN initial_position_cost DECIMAL(20, 8) DEFAULT 0 COMMENT '创建时持仓的名义价值(可选)',
ADD COLUMN total_realized_pnl DECIMAL(20, 8) DEFAULT 0 COMMENT '累计已实现盈亏(缓存)',
ADD COLUMN total_commission DECIMAL(20, 8) DEFAULT 0 COMMENT '累计手续费';
```

**字段说明**:
- `initial_balance`: **核心字段**,系统接管时的 walletBalance,用于 Equity 公式,不再改变
- `original_deposit`: 可选字段,用户原始充值金额,用于展示"用户总收益率"
- `initial_position_cost`: 可选字段,创建时持仓的名义价值,用于分析
- `total_realized_pnl`: 冗余字段,从 orders 表同步,提升查询性能
- `total_commission`: 累计手续费

**InitialBalance 统计规则**:
| 场景 | initial_balance | original_deposit | 说明 |
|------|----------------|------------------|------|
| 创建,无仓位 | walletBalance | walletBalance | 相同 |
| 创建,有仓位 | walletBalance | 用户输入 | 可能不同 |
| 重启 | 数据库值(不变) | 数据库值 | 不变 |

---

### 2. 新增 `orders` 表(唯一新增的表)

```sql
CREATE TABLE orders (
    id BIGINT AUTO_INCREMENT PRIMARY KEY,
    trader_id VARCHAR(64) NOT NULL,

    -- 订单标识
    order_id VARCHAR(128),                       -- 交易所订单ID
    client_order_id VARCHAR(128) UNIQUE,         -- 客户端订单ID(唯一,用于幂等)

    -- 订单基本信息
    symbol VARCHAR(32) NOT NULL,
    side ENUM('BUY', 'SELL') NOT NULL,
    position_side ENUM('LONG', 'SHORT') NOT NULL,
    reduce_only BOOLEAN DEFAULT FALSE,           -- 是否平仓单

    -- 订单状态
    status ENUM('NEW', 'PARTIALLY_FILLED', 'FILLED', 'CANCELED', 'EXPIRED', 'REJECTED')
        NOT NULL DEFAULT 'FILLED' COMMENT '订单状态',

    -- 价格和数量
    quantity DECIMAL(20, 8) NOT NULL,            -- 委托数量
    filled_quantity DECIMAL(20, 8) DEFAULT 0,    -- 实际成交数量
    avg_price DECIMAL(20, 8),                    -- 成交均价

    -- ✅ 核心: 跟踪剩余未平仓数量(仅开仓订单使用)
    remaining_quantity DECIMAL(20, 8) DEFAULT 0 COMMENT '剩余未平仓数量',

    -- ✅ 核心: 盈亏和手续费
    realized_pnl DECIMAL(20, 8) DEFAULT 0,       -- 已实现盈亏(平仓时计算)
    commission DECIMAL(20, 8) DEFAULT 0,         -- 手续费(USDT计价)

    -- ✅ 来源标记(仅用于审计,不影响计算)
    is_synthetic BOOLEAN DEFAULT FALSE COMMENT '是否为虚拟订单',
    sync_source ENUM('NORMAL', 'EXCHANGE_SYNC', 'MANUAL_IMPORT') DEFAULT 'NORMAL'
        COMMENT '订单来源',

    -- 时间戳
    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    updated_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,

    -- 关联信息
    cycle_number INT,                            -- 所属交易周期

    -- 原始数据(JSON,用于debug和对账)
    exchange_response JSON,

    INDEX idx_trader_id (trader_id),
    INDEX idx_trader_symbol (trader_id, symbol, position_side),
    INDEX idx_remaining (trader_id, remaining_quantity),
    INDEX idx_status (status),
    INDEX idx_created_at (created_at),
    FOREIGN KEY (trader_id) REFERENCES traders(id) ON DELETE CASCADE
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COMMENT='订单记录表';
```

**设计要点**:
1. **status 字段**: 跟踪订单状态,只统计FILLED的订单
2. **filled_quantity**: 实际成交数量,处理部分成交
3. **remaining_quantity**: ✅ **关键字段** - 跟踪开仓订单的剩余未平仓数量
4. **is_synthetic / sync_source**: ✅ **仅用于审计** - 不影响计算逻辑
5. **commission (USDT)**: 统一转换为USDT计价
6. **client_order_id UNIQUE**: 防止重复记录

---

## 🔧 核心实现

### 0. 启动流程(新增仓位同步步骤)

```go
// ✅ 新增: 初始化时必须执行仓位同步
func (at *AutoTrader) Initialize(isNewTrader bool) error {
    log.Printf("🔄 初始化 trader: %s", at.id)

    // 1. 恢复数据库状态
    if !isNewTrader {
        if err := at.restoreFromDB(); err != nil {
            return fmt.Errorf("恢复数据库状态失败: %w", err)
        }
    }

    // 2. ✅ 仓位同步(关键步骤)
    if err := at.syncPositions(isNewTrader); err != nil {
        return fmt.Errorf("仓位同步失败: %w", err)
    }

    // 3. 验证对账
    if err := at.verifyAccountBalance(); err != nil {
        log.Printf("⚠️ 对账验证发现差异: %v", err)
    }

    log.Printf("✓ Trader %s 初始化成功", at.id)
    return nil
}
```

---

### 1. 仓位同步(唯一需要区分的地方)

```go
// syncPositions 仓位同步 - 发现并补齐虚拟订单
func (at *AutoTrader) syncPositions(isCreation bool) error {
    log.Printf("🔄 开始仓位同步 (isCreation=%v)", isCreation)

    // 1. 从交易所获取当前持仓
    exchangePositions, err := at.getExchangePositions()
    if err != nil {
        return fmt.Errorf("获取交易所持仓失败: %w", err)
    }

    // 2. 从 orders 表计算应有持仓
    dbPositions, err := at.getPositionsFromDB()
    if err != nil {
        return fmt.Errorf("从数据库计算持仓失败: %w", err)
    }

    // 3. ✅ 对比找出孤儿仓位
    orphans := at.findOrphanPositions(exchangePositions, dbPositions)

    if len(orphans) == 0 {
        log.Printf("✓ 仓位同步完成,无孤儿仓位")

        // 如果是初次创建且无仓位,设置 initial_balance
        if isCreation {
            return at.setInitialBalance()
        }
        return nil
    }

    // 4. ✅ 发现孤儿仓位 - 告警
    log.Printf("⚠️ 发现 %d 个孤儿仓位:", len(orphans))
    for _, orphan := range orphans {
        log.Printf("  - %s %s: qty=%.4f, entryPrice=%.2f",
            orphan.Symbol, orphan.Side, orphan.Quantity, orphan.EntryPrice)
    }

    // 发送告警
    at.alertManager.SendAlert("orphan_positions_detected", map[string]interface{}{
        "trader_id": at.id,
        "count": len(orphans),
        "positions": orphans,
        "is_creation": isCreation,
    })

    // 5. ✅ 处理孤儿仓位
    if isCreation {
        return at.handleOrphanPositionsOnCreation(orphans)
    } else {
        return at.handleOrphanPositionsOnRuntime(orphans)
    }
}

// 从交易所获取持仓
func (at *AutoTrader) getExchangePositions() ([]Position, error) {
    resp, err := at.trader.GetPositions()
    if err != nil {
        return nil, err
    }

    var positions []Position
    for _, p := range resp {
        qty := getFloat64Field(p, "positionAmt")
        if math.Abs(qty) < 0.00001 {
            continue  // 跳过空仓
        }

        side := "LONG"
        if qty < 0 {
            side = "SHORT"
            qty = -qty
        }

        positions = append(positions, Position{
            Symbol:     getStringField(p, "symbol"),
            Side:       side,
            Quantity:   qty,
            EntryPrice: getFloat64Field(p, "entryPrice"),
        })
    }

    return positions, nil
}

// 从 orders 表计算应有持仓
func (at *AutoTrader) getPositionsFromDB() (map[string]Position, error) {
    rows, err := at.db.Query(`
        SELECT
            symbol,
            position_side,
            SUM(remaining_quantity) as total_qty,
            SUM(remaining_quantity * avg_price) / SUM(remaining_quantity) as avg_entry
        FROM orders
        WHERE trader_id = ?
          AND reduce_only = FALSE
          AND status = 'FILLED'
          AND remaining_quantity > 0
        GROUP BY symbol, position_side
    `, at.id)

    if err != nil {
        return nil, err
    }
    defer rows.Close()

    positions := make(map[string]Position)
    for rows.Next() {
        var symbol, side string
        var qty, entry float64
        rows.Scan(&symbol, &side, &qty, &entry)

        key := symbol + "_" + side
        positions[key] = Position{
            Symbol:     symbol,
            Side:       side,
            Quantity:   qty,
            EntryPrice: entry,
        }
    }

    return positions, nil
}

// 找出孤儿仓位
func (at *AutoTrader) findOrphanPositions(
    exchangePos []Position,
    dbPos map[string]Position,
) []Position {
    var orphans []Position

    for _, exPos := range exchangePos {
        key := exPos.Symbol + "_" + exPos.Side
        dbP, exists := dbPos[key]

        if !exists {
            // 完全没有记录
            orphans = append(orphans, exPos)
        } else if math.Abs(exPos.Quantity - dbP.Quantity) > 0.00001 {
            // 数量不匹配
            orphans = append(orphans, Position{
                Symbol:     exPos.Symbol,
                Side:       exPos.Side,
                Quantity:   exPos.Quantity - dbP.Quantity,
                EntryPrice: exPos.EntryPrice,
            })
        }
    }

    return orphans
}

// 处理创建时的孤儿仓位
func (at *AutoTrader) handleOrphanPositionsOnCreation(orphans []Position) error {
    tx, err := at.db.Begin()
    if err != nil {
        return err
    }
    defer tx.Rollback()

    // 为每个孤儿仓位创建虚拟订单
    for _, orphan := range orphans {
        if err := at.createSyntheticOrderInTx(tx, orphan, "EXCHANGE_SYNC"); err != nil {
            return err
        }
    }

    // ✅ 设置 initial_balance = walletBalance
    balance, err := at.trader.GetBalance()
    if err != nil {
        return err
    }
    walletBalance := getFloat64Field(balance, "totalWalletBalance")

    _, err = tx.Exec(`
        UPDATE traders
        SET initial_balance = ?,
            total_realized_pnl = 0,
            total_commission = 0
        WHERE id = ?
    `, walletBalance, at.id)

    if err != nil {
        return err
    }

    if err = tx.Commit(); err != nil {
        return err
    }

    at.initialBalance = walletBalance
    log.Printf("✓ 创建时有仓位: initial_balance=%.2f, 已创建 %d 个虚拟订单",
        walletBalance, len(orphans))

    return nil
}

// 处理运行时的孤儿仓位(用户手动开仓)
func (at *AutoTrader) handleOrphanPositionsOnRuntime(orphans []Position) error {
    log.Printf("🚨 CRITICAL: 运行时发现孤儿仓位!")
    log.Printf("   可能原因: 用户手动开仓")
    log.Printf("   操作: 创建虚拟订单并接管")

    tx, err := at.db.Begin()
    if err != nil {
        return err
    }
    defer tx.Rollback()

    for _, orphan := range orphans {
        if err := at.createSyntheticOrderInTx(tx, orphan, "MANUAL_IMPORT"); err != nil {
            return err
        }
    }

    if err = tx.Commit(); err != nil {
        return err
    }

    log.Printf("✓ 已创建 %d 个虚拟订单,仓位已接管", len(orphans))
    return nil
}

// 创建虚拟订单
func (at *AutoTrader) createSyntheticOrderInTx(tx *sql.Tx, pos Position, source string) error {
    syntheticOrderID := fmt.Sprintf("SYNC_%s_%s_%d", pos.Symbol, pos.Side, time.Now().UnixMilli())

    _, err := tx.Exec(`
        INSERT INTO orders (
            trader_id, order_id, client_order_id, symbol, side, position_side,
            reduce_only, status, quantity, filled_quantity, avg_price,
            remaining_quantity, realized_pnl, commission,
            is_synthetic, sync_source, exchange_response
        ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
    `, at.id, syntheticOrderID, syntheticOrderID, pos.Symbol,
       "BUY", pos.Side, false, "FILLED", pos.Quantity, pos.Quantity,
       pos.EntryPrice, pos.Quantity, 0, 0, true, source,
       toJSON(map[string]interface{}{
           "synthetic": true,
           "source": source,
           "timestamp": time.Now(),
       }))

    if err != nil {
        return fmt.Errorf("创建虚拟订单失败: %w", err)
    }

    log.Printf("  ✓ 虚拟订单: %s %s qty=%.4f price=%.2f source=%s",
        pos.Symbol, pos.Side, pos.Quantity, pos.EntryPrice, source)

    return nil
}
```

---

### 2. 后续操作 - 完全统一处理

```go
// ===== 平仓逻辑 - 不区分订单来源 =====
func (at *AutoTrader) executeCloseLong(decision *Decision) error {
    // 1. 交易所平仓
    order, err := at.trader.CloseLong(decision.Symbol, decision.Quantity)
    if err != nil {
        return fmt.Errorf("交易所平仓失败: %w", err)
    }

    // 2. ✅ 使用事务保证一致性
    tx, err := at.db.Begin()
    if err != nil {
        return err
    }
    defer tx.Rollback()

    // 3. 提取订单信息
    avgPrice := getFloat64Field(order, "avgPrice")
    executedQty := getFloat64Field(order, "executedQty")
    commission, _ := at.calculateCommissionInUSDT(order)

    // 4. ✅ 计算已实现盈亏 - FIFO匹配所有订单(含虚拟订单)
    realizedPnL, err := at.calculateRealizedPnLInTx(tx, decision.Symbol, "LONG", executedQty, avgPrice)
    if err != nil {
        return err
    }

    // 5. 记录平仓订单
    _, err = tx.Exec(`
        INSERT INTO orders (
            trader_id, order_id, client_order_id, symbol, side, position_side,
            reduce_only, status, quantity, filled_quantity, avg_price,
            remaining_quantity, realized_pnl, commission,
            cycle_number, exchange_response
        ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
    `, at.id, getStringField(order, "orderId"), getStringField(order, "clientOrderId"),
       decision.Symbol, "SELL", "LONG", true, "FILLED",
       executedQty, executedQty, avgPrice, 0, realizedPnL, commission,
       at.cycleNumber, toJSON(order))

    if err != nil {
        return err
    }

    // 6. 原子更新 traders 表
    _, err = tx.Exec(`
        UPDATE traders
        SET total_realized_pnl = total_realized_pnl + ?,
            total_commission = total_commission + ?
        WHERE id = ?
    `, realizedPnL, commission, at.id)

    if err != nil {
        return err
    }

    // 7. 提交事务
    if err = tx.Commit(); err != nil {
        return err
    }

    // 8. ✅ 只在事务成功后更新内存
    at.pnlMutex.Lock()
    at.totalRealizedPnL += realizedPnL
    at.totalCommission += commission
    at.pnlMutex.Unlock()

    log.Printf("✓ 平仓成功: %s LONG, PnL=%.2f, Total=%.2f",
        decision.Symbol, realizedPnL, at.totalRealizedPnL)

    return nil
}

// ===== FIFO 盈亏计算 - 不区分订单来源 =====
func (at *AutoTrader) calculateRealizedPnLInTx(
    tx *sql.Tx,
    symbol, side string,
    closeQty, closePrice float64,
) (float64, error) {
    // ✅ 查询所有有剩余数量的开仓订单(含虚拟订单)
    // 注意: 不过滤 is_synthetic 字段
    rows, err := tx.Query(`
        SELECT id, avg_price, remaining_quantity, is_synthetic
        FROM orders
        WHERE trader_id = ?
          AND symbol = ?
          AND position_side = ?
          AND reduce_only = FALSE
          AND status = 'FILLED'
          AND remaining_quantity > 0
        ORDER BY created_at ASC
        FOR UPDATE
    `, at.id, symbol, side)

    if err != nil {
        return 0, err
    }
    defer rows.Close()

    totalPnL := 0.0
    remainingCloseQty := closeQty

    // ✅ FIFO 匹配并更新
    for rows.Next() && remainingCloseQty > 0 {
        var orderID int64
        var entryPrice, remainingQty float64
        var isSynthetic bool

        rows.Scan(&orderID, &entryPrice, &remainingQty, &isSynthetic)

        // 计算本次匹配数量
        matchQty := math.Min(remainingQty, remainingCloseQty)

        // 计算盈亏
        var pnl float64
        if side == "LONG" {
            pnl = (closePrice - entryPrice) * matchQty
        } else {
            pnl = (entryPrice - closePrice) * matchQty
        }

        totalPnL += pnl
        remainingCloseQty -= matchQty

        // ✅ 更新剩余数量
        newRemaining := remainingQty - matchQty
        _, err := tx.Exec(`UPDATE orders SET remaining_quantity = ? WHERE id = ?`,
            newRemaining, orderID)
        if err != nil {
            return 0, err
        }

        // 日志中可以显示是否为虚拟订单(仅供参考)
        synFlag := ""
        if isSynthetic {
            synFlag = " [虚拟]"
        }
        log.Printf("  📊 匹配%s: OrderID=%d, Entry=%.2f, Match=%.4f, PnL=%.2f, Remaining=%.4f",
            synFlag, orderID, entryPrice, matchQty, pnl, newRemaining)
    }

    if remainingCloseQty > 0.00001 {
        log.Printf("⚠️ 平仓数量未完全匹配: 剩余 %.4f", remainingCloseQty)
    }

    return totalPnL, nil
}

// ===== 开仓逻辑 - 统一处理 =====
func (at *AutoTrader) executeOpenLong(decision *Decision) error {
    // 1. 交易所开仓
    order, err := at.trader.OpenLong(decision.Symbol, decision.Quantity, decision.Leverage)
    if err != nil {
        return err
    }

    // 2. 记录订单(带重试)
    err = at.recordOrderWithRetry(order, decision, false)
    if err != nil {
        // 加入修复队列
        at.repairQueue <- &RepairTask{
            OrderID: getStringField(order, "orderId"),
            Action: "record_missing_order",
        }

        at.alertManager.SendAlert("order_record_failed", map[string]interface{}{
            "order_id": getStringField(order, "orderId"),
            "symbol": decision.Symbol,
        })
    }

    return nil
}

// ===== 记录订单 - 统一处理 =====
func (at *AutoTrader) recordOrder(order map[string]interface{}, decision *Decision, reduceOnly bool) error {
    // 安全提取字段
    orderID := getStringField(order, "orderId")
    if orderID == "" {
        return fmt.Errorf("missing orderId")
    }

    clientOrderID := getStringField(order, "clientOrderId")
    avgPrice := getFloat64Field(order, "avgPrice")
    if avgPrice == 0 {
        return fmt.Errorf("invalid avgPrice")
    }

    executedQty := getFloat64Field(order, "executedQty")
    if executedQty == 0 {
        return fmt.Errorf("executedQty is zero")
    }

    commission, err := at.calculateCommissionInUSDT(order)
    if err != nil {
        log.Printf("⚠️ 手续费计算失败: %v", err)
        commission = 0
    }

    status := getStringField(order, "status")
    if status == "" {
        status = "FILLED"
    }

    // 开仓: remaining_quantity = executedQty
    // 平仓: remaining_quantity = 0
    remainingQty := 0.0
    realizedPnL := 0.0

    if !reduceOnly {
        remainingQty = executedQty
    } else {
        // 平仓时需要计算盈亏(在调用方已计算)
        realizedPnL = 0  // 这里为0,实际在 executeCloseLong 中计算
    }

    _, err = at.db.Exec(`
        INSERT INTO orders (
            trader_id, order_id, client_order_id, symbol, side, position_side,
            reduce_only, status, quantity, filled_quantity, avg_price,
            remaining_quantity, realized_pnl, commission,
            is_synthetic, sync_source,
            cycle_number, exchange_response
        ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        ON DUPLICATE KEY UPDATE
            status = VALUES(status),
            filled_quantity = VALUES(filled_quantity),
            avg_price = VALUES(avg_price),
            remaining_quantity = VALUES(remaining_quantity)
    `, at.id, orderID, clientOrderID, decision.Symbol,
       decision.Side, decision.Side, reduceOnly, status, executedQty, executedQty,
       avgPrice, remainingQty, realizedPnL, commission,
       false, "NORMAL",  // ✅ 正常订单
       at.cycleNumber, toJSON(order))

    return err
}
```

---

### 3. 辅助函数

```go
// 安全的字段提取
func getStringField(m map[string]interface{}, key string) string {
    if v, ok := m[key]; ok {
        switch val := v.(type) {
        case string:
            return val
        case float64:
            return fmt.Sprintf("%.0f", val)
        case int, int64:
            return fmt.Sprintf("%d", val)
        }
    }
    return ""
}

func getFloat64Field(m map[string]interface{}, key string) float64 {
    if v, ok := m[key]; ok {
        switch val := v.(type) {
        case float64:
            return val
        case string:
            f, _ := strconv.ParseFloat(val, 64)
            return f
        case int:
            return float64(val)
        case int64:
            return float64(val)
        }
    }
    return 0
}

// 转换手续费为USDT
func (at *AutoTrader) calculateCommissionInUSDT(order map[string]interface{}) (float64, error) {
    commission := getFloat64Field(order, "commission")
    asset := getStringField(order, "commissionAsset")

    if asset == "" || asset == "USDT" {
        return commission, nil
    }

    // 转换为USDT
    price, err := at.trader.GetPrice(asset + "USDT")
    if err != nil {
        return 0, fmt.Errorf("get %s price failed: %w", asset, err)
    }

    return commission * price, nil
}

// 重试机制
func (at *AutoTrader) recordOrderWithRetry(order map[string]interface{}, decision *Decision, reduceOnly bool) error {
    var lastErr error
    for i := 0; i < 3; i++ {
        err := at.recordOrder(order, decision, reduceOnly)
        if err == nil {
            return nil
        }
        lastErr = err
        time.Sleep(time.Second * time.Duration(1 << i))
    }
    return fmt.Errorf("record order failed after retries: %w", lastErr)
}
```

---

### 4. 重启恢复逻辑

```go
func (at *AutoTrader) restoreFromDB() error {
    // 1. 从 traders 表读取
    err := at.db.QueryRow(`
        SELECT initial_balance, original_deposit, total_realized_pnl, total_commission
        FROM traders WHERE id = ?
    `, at.id).Scan(&at.initialBalance, &at.originalDeposit, &at.totalRealizedPnL, &at.totalCommission)

    if err != nil {
        return fmt.Errorf("restore failed: %w", err)
    }

    // 2. ✅ 双重验证: 从 orders 表重新计算
    var dbRealizedPnL, dbCommission float64
    err = at.db.QueryRow(`
        SELECT
            COALESCE(SUM(realized_pnl), 0),
            COALESCE(SUM(commission), 0)
        FROM orders
        WHERE trader_id = ?
          AND reduce_only = TRUE
          AND status = 'FILLED'
    `, at.id).Scan(&dbRealizedPnL, &dbCommission)

    if err != nil {
        return fmt.Errorf("calculate from orders failed: %w", err)
    }

    // 3. ✅ 严格对账
    diff := math.Abs(dbRealizedPnL - at.totalRealizedPnL)
    if diff > 0.01 {
        log.Printf("🚨 CRITICAL: PnL mismatch!")
        log.Printf("   traders.total_realized_pnl = %.8f", at.totalRealizedPnL)
        log.Printf("   SUM(orders.realized_pnl)   = %.8f", dbRealizedPnL)
        log.Printf("   Difference                 = %.8f", diff)

        // 发送告警
        at.alertManager.SendAlert("pnl_mismatch", map[string]interface{}{
            "trader_id": at.id,
            "diff": diff,
            "cached": at.totalRealizedPnL,
            "calculated": dbRealizedPnL,
        })

        // 差异过大时阻断
        if diff > 1.0 {
            return fmt.Errorf("PnL mismatch too large (%.2f USDT)", diff)
        }

        // 以 orders 表为准
        at.totalRealizedPnL = dbRealizedPnL
        at.totalCommission = dbCommission

        at.db.Exec(`UPDATE traders SET total_realized_pnl = ?, total_commission = ? WHERE id = ?`,
            dbRealizedPnL, dbCommission, at.id)
    }

    log.Printf("✓ Restored: InitialBalance=%.2f, RealizedPnL=%.2f",
        at.initialBalance, at.totalRealizedPnL)

    return nil
}
```

---

### 5. 计算净值(最终API)

```go
func (at *AutoTrader) GetAccountInfo() (map[string]interface{}, error) {
    // 1. 从交易所获取
    balance, err := at.trader.GetBalance()
    if err != nil {
        return nil, err
    }

    walletBalance := getFloat64Field(balance, "totalWalletBalance")
    unrealizedPnL := getFloat64Field(balance, "totalUnrealizedProfit")
    availableBalance := getFloat64Field(balance, "availableBalance")

    // 2. 从内存读取(已从数据库恢复)
    at.pnlMutex.RLock()
    realizedPnL := at.totalRealizedPnL
    commission := at.totalCommission
    initialBalance := at.initialBalance
    originalDeposit := at.originalDeposit
    at.pnlMutex.RUnlock()

    // 3. ✅ 计算净值和收益率
    totalPnL := realizedPnL + unrealizedPnL
    totalEquity := initialBalance + totalPnL

    // 系统收益率(基于系统接管时)
    systemReturnPct := 0.0
    if initialBalance > 0 {
        systemReturnPct = (totalPnL / initialBalance) * 100
    }

    // 用户总收益率(基于原始充值)
    totalReturnPct := 0.0
    if originalDeposit > 0 {
        totalReturnPct = ((totalEquity - originalDeposit) / originalDeposit) * 100
    }

    // 4. ✅ 对账验证
    exchangeEquity := walletBalance + unrealizedPnL
    equityDiff := totalEquity - exchangeEquity

    if math.Abs(equityDiff) > 0.1 {
        log.Printf("⚠️ Equity mismatch: Calculated=%.2f, Exchange=%.2f, Diff=%.2f",
            totalEquity, exchangeEquity, equityDiff)

        at.alertManager.SendAlert("equity_mismatch", map[string]interface{}{
            "calculated": totalEquity,
            "exchange": exchangeEquity,
            "diff": equityDiff,
        })
    }

    return map[string]interface{}{
        // ===== 基准信息 =====
        "initial_balance":   initialBalance,   // 系统接管时的余额
        "original_deposit":  originalDeposit,  // 用户原始充值

        // ===== 当前状态 =====
        "total_equity":      totalEquity,      // 总净值
        "wallet_balance":    walletBalance,    // 钱包余额
        "available_balance": availableBalance, // 可用余额

        // ===== 盈亏分析 =====
        "realized_pnl":      realizedPnL,      // 已实现盈亏
        "unrealized_pnl":    unrealizedPnL,    // 未实现盈亏
        "total_pnl":         totalPnL,         // 总盈亏
        "total_commission":  commission,       // 累计手续费

        // ===== 收益率(两种视角) =====
        "system_return_pct": systemReturnPct,  // 系统管理收益率
        "total_return_pct":  totalReturnPct,   // 用户总收益率

        // ===== 对账信息 =====
        "exchange_equity":   exchangeEquity,   // 交易所计算的净值
        "equity_diff":       equityDiff,       // 差异
    }, nil
}
```

---

## 🎯 API 响应示例

```json
{
  "trader_id": "trader_123",

  // ===== 基准信息 =====
  "initial_balance": 95.0,
  "original_deposit": 100.0,

  // ===== 当前状态 =====
  "total_equity": 105.0,
  "wallet_balance": 105.0,
  "available_balance": 80.0,

  // ===== 盈亏分析 =====
  "realized_pnl": 10.0,
  "unrealized_pnl": 0.0,
  "total_pnl": 10.0,
  "total_commission": 0.5,

  // ===== 收益率(两种视角) =====
  "system_return_pct": 10.53,
  "total_return_pct": 5.0,

  // ===== 对账信息 =====
  "exchange_equity": 105.0,
  "equity_diff": 0.0,

  // ===== 说明 =====
  "note": "system_return: 从系统接管时起算; total_return: 从用户原始充值起算"
}
```

---

## ✅ 优势对比

| 方案 | 新增表 | 复杂度 | 功能 | 统一性 |
|------|-------|--------|------|--------|
| v1.0 完整版 | 3个 | 高 | 100% | 中 |
| v2.1 修复版 | 1个 | 中 | 95% | 中 |
| **v2.2 统一版** | **1个** | **低** ✅ | **95%** | **高** ✅ |

### v2.2 核心改进
1. ✅ **统一处理**: 后续操作不区分订单来源
2. ✅ **代码简化**: 减少50%的if分支
3. ✅ **易于维护**: 单一代码路径
4. ✅ **不易出错**: 逻辑统一,减少bug
5. ✅ **易于测试**: 测试用例简化

---

## 🔧 API层改动

### 1. handleCreateTrader 修复 (api/server.go:534-604)

**问题描述**：

当前实现在创建trader时，会将 `totalEquity` (walletBalance + unrealizedPnL) 设置为 `initial_balance`：

```go
// ❌ 错误的实现 (lines 597-600)
// Total equity = wallet balance + unrealized P&L
totalEquity := totalWalletBalance + totalUnrealizedProfit
if totalEquity > 0 {
    actualBalance = totalEquity  // ❌ 错误！应该用 walletBalance
}
```

**为什么这是错误的？**

根据设计，`initial_balance` 应该等于系统接管时的 `walletBalance`，而不是 `totalEquity`。

**问题影响**：
```
假设创建时：
- walletBalance = 95 USDT
- unrealizedPnL = +5 USDT
- totalEquity = 100 USDT

错误设置：
  initial_balance = 100 (totalEquity)

后续计算 Equity：
  Equity = InitialBalance + RealizedPnL + UnrealizedPnL
         = 100 + 0 + 5 = 105 ❌ 错误！

正确应该是：
  initial_balance = 95 (walletBalance)
  Equity = 95 + 0 + 5 = 100 ✅
```

**修复方案**：

```go
// ✅ 正确的实现
if createErr != nil {
    log.Printf("⚠️ 创建临时 trader 失败，使用用户输入的初始资金: %v", createErr)
} else if tempTrader != nil {
    // 查询实际余额
    balanceInfo, balanceErr := tempTrader.GetBalance()
    if balanceErr != nil {
        log.Printf("⚠️ 查询交易所余额失败，使用用户输入的初始资金: %v", balanceErr)
    } else {
        // ✅ 关键修复：只提取 walletBalance，不包含 unrealizedPnL
        totalWalletBalance := 0.0

        if wallet, ok := balanceInfo["totalWalletBalance"].(float64); ok {
            totalWalletBalance = wallet
        }

        // ✅ 设置 initial_balance = walletBalance（不是 equity）
        if totalWalletBalance > 0 {
            actualBalance = totalWalletBalance
            log.Printf("✓ 从交易所查询到钱包余额: %.2f USDT", totalWalletBalance)
        }
    }
}

// 创建交易员配置（数据库实体）
trader := &config.TraderRecord{
    ID:             traderID,
    UserID:         userID,
    Name:           req.Name,
    AIModelID:      req.AIModelID,
    ExchangeID:     req.ExchangeID,
    InitialBalance: actualBalance, // ✅ 现在是正确的 walletBalance
    // ... 其他字段
}
```

**改动总结**：

| 项目 | 原实现 | 修复后 |
|------|--------|--------|
| 获取余额 | `totalEquity = wallet + unrealized` ❌ | `walletBalance` ✅ |
| 设置值 | `actualBalance = totalEquity` ❌ | `actualBalance = walletBalance` ✅ |
| 删除变量 | `totalUnrealizedProfit` (不需要) | - |

---

### 2. handleEquityHistory 修复 (api/server.go:1514-1598)

**问题描述**：

当前实现在无法从 `trader.GetStatus()` 获取 `initial_balance` 时，会使用第一条记录的 equity 作为 fallback：

```go
// ❌ 错误的fallback逻辑 (lines 1558-1562)
if initialBalance == 0 && len(records) > 0 {
    // 第一条记录的equity作为初始余额
    initialBalance = records[0].AccountState.TotalBalance + records[0].AccountState.TotalUnrealizedProfit
}
```

**为什么这是错误的？**

根据新的PNL设计：
- `initial_balance` 是系统接管时的 `walletBalance`（固定值）
- 如果创建时有仓位，第一条记录的 equity 可能已经 ≠ initial_balance
- 使用第一条记录作为 fallback 会导致计算错误

**示例**：
```
假设创建trader时：
- walletBalance = 95 USDT
- 有仓位，unrealizedPnL = +5 USDT
- initial_balance = 95 ✅ (正确)

第一条decision记录：
- equity = 95 + 5 = 100

如果使用第一条记录的fallback：
- 错误的 initialBalance = 100
- 后续计算 totalPnL = equity - 100 (错误！应该是 - 95)
- 盈亏被低估了 5 USDT
```

**修复方案**：

```go
// ✅ 正确的实现
func (s *Server) handleEquityHistory(c *gin.Context) {
    // ... 省略前面的代码 ...

    // 从AutoTrader获取初始余额（用于计算盈亏百分比）
    initialBalance := 0.0
    if status := trader.GetStatus(); status != nil {
        if ib, ok := status["initial_balance"].(float64); ok && ib > 0 {
            initialBalance = ib
        }
    }

    // ✅ 删除错误的fallback逻辑
    // 不要使用第一条记录作为初始余额

    // 如果无法获取initial_balance，直接返回错误
    if initialBalance == 0 {
        c.JSON(http.StatusInternalServerError, gin.H{
            "error": "无法获取初始余额，请确保交易员已正确初始化",
        })
        return
    }

    // ✅ 计算逻辑保持不变（已经是正确的）
    var history []EquityPoint
    for _, record := range records {
        walletBalance := record.AccountState.TotalBalance
        unrealizedPnL := record.AccountState.TotalUnrealizedProfit
        totalEquity := walletBalance + unrealizedPnL
        totalPnL := totalEquity - initialBalance  // ✅ 正确

        totalPnLPct := 0.0
        if initialBalance > 0 {
            totalPnLPct = (totalPnL / initialBalance) * 100  // ✅ 正确
        }

        history = append(history, EquityPoint{
            Timestamp:        record.Timestamp.Format("2006-01-02 15:04:05"),
            TotalEquity:      totalEquity,
            AvailableBalance: record.AccountState.AvailableBalance,
            TotalPnL:         totalPnL,
            TotalPnLPct:      totalPnLPct,
            PositionCount:    record.AccountState.PositionCount,
            MarginUsedPct:    record.AccountState.MarginUsedPct,
            CycleNumber:      record.CycleNumber,
        })
    }

    c.JSON(http.StatusOK, history)
}
```

**改动总结**：

| 项目 | 需要改 | 说明 |
|------|-------|------|
| 删除 fallback 逻辑 | ✅ 是 | 删除 lines 1558-1562 |
| 从 status 获取 initial_balance | ✅ 保持 | 正确的获取方式 |
| 计算公式 | ✅ 保持 | `totalPnL = equity - initialBalance` 已经正确 |
| 错误处理 | ✅ 保持 | 无法获取时返回错误 |

**验证方法**：

修复后，测试以下场景：
```
1. 创建trader，无仓位
   - initial_balance = walletBalance
   - 第一条记录的 totalPnL 应该 = 0

2. 创建trader，有仓位（如 unrealizedPnL = +5）
   - initial_balance = walletBalance (如95)
   - 第一条记录的 totalPnL 应该 = +5 (不是0)
   - 第一条记录的 totalEquity = 95 + 5 = 100

3. 后续运行
   - 所有 totalPnL 都基于固定的 initial_balance 计算
   - 盈亏百分比准确反映从系统接管以来的收益
```

---

### 3. handleSyncBalance - ⚠️ 暂不实现

**功能说明**：

这是一个手动同步功能，允许用户在特殊情况下重置 `initial_balance`（如充值、提现后）。

**决定：暂不实现此功能**

**原因**：

1. ⚠️ **破坏数据一致性**：改变 `initial_balance` 会导致历史盈亏统计失真
2. ⚠️ **语义混乱**：`initial_balance` 的定义是"系统接管时的固定基准"，不应该变化
3. ⚠️ **容易误用**：用户可能误以为这是"同步余额"功能而频繁使用，破坏盈亏计算的准确性

**替代方案**：

如果用户充值/提现，推荐以下处理方式：

**方案A：保持 initial_balance 不变（推荐）**
```
假设用户充值 100 USDT:
- initial_balance 保持不变（如95）
- walletBalance 增加到 195
- Equity = 195 + RealizedPnL + UnrealizedPnL
- 收益率 = (Equity - 95) / 95
- 这样可以准确反映AI从接管以来的总体表现（包括充值）
```

**方案B：创建新 trader**
```
如果用户充值后想重新开始统计:
1. 停止旧 trader
2. 创建新 trader（新的 initial_balance = 新的 walletBalance）
3. 历史数据保留在旧 trader 中
4. 优点：数据清晰，逻辑简单
```

**当前 API 的实现问题**（仅供参考，不修复）：

当前 `handleSyncBalance` 使用 `availableBalance` 而非 `totalWalletBalance`，如果有仓位会导致设置错误。但因为决定不实现此功能，所以不需要修复。如果未来要实现，必须使用 `totalWalletBalance`

---

### 📊 API层改动总结

**核心问题**：API错误地使用了包含 `unrealizedPnL` 的值来设置或获取 `initial_balance`。

| API | 问题 | 影响 | 严重程度 | 处理方式 |
|-----|------|------|---------|---------|
| `handleCreateTrader` | 使用 `totalEquity` 而非 `walletBalance` | 创建时有仓位会导致initial_balance虚高 | 🔴 高 | 立即修复 |
| `handleEquityHistory` | 使用第一条记录的equity作为fallback | 历史盈亏计算错误 | 🟡 中 | 立即修复 |
| `handleSyncBalance` | 使用 `availableBalance` 而非 `walletBalance` | 有仓位时会导致initial_balance偏低 | - | ⚠️ 暂不实现 |

**修复要点**：

1. **统一原则**：`initial_balance` **永远等于** `totalWalletBalance`
2. **不要包含**：`unrealizedPnL`、`availableBalance`、`totalEquity`
3. **公式验证**：`Equity = InitialBalance + RealizedPnL + UnrealizedPnL` 必须成立

**修复优先级**：

1. 🔴 **P0 - handleCreateTrader**: 立即修复（影响所有新创建的trader）
2. 🟡 **P1 - handleEquityHistory**: 尽快修复（影响前端展示，但不影响核心计算）
3. ⚪ **handleSyncBalance**: 暂不实现（设计上不应该改变initial_balance）

**测试验证**：

修复后，使用以下场景验证：
```bash
# 场景1：创建trader时有仓位
POST /api/traders
# 预期：initial_balance = walletBalance (如95)
# 不应该：initial_balance = equity (如100)

# 场景2：查询历史收益
GET /api/equity-history
# 预期：totalPnL基于正确的initial_balance计算
# 不应该：使用第一条记录作为基准

# 场景3：用户充值后
# 推荐方案A：保持initial_balance不变，Equity自动包含充值
# 推荐方案B：创建新trader，重新开始统计
```

---

## 🚀 实施步骤（基于现有SQLite数据库）

### 📋 现有数据库结构分析

**当前 traders 表**（config/database.go:149-168）：
```sql
CREATE TABLE IF NOT EXISTS traders (
    id TEXT PRIMARY KEY,
    user_id TEXT NOT NULL DEFAULT 'default',
    name TEXT NOT NULL,
    ai_model_id TEXT NOT NULL,
    exchange_id TEXT NOT NULL,
    initial_balance REAL NOT NULL,  -- ✅ 已存在
    scan_interval_minutes INTEGER DEFAULT 3,
    is_running BOOLEAN DEFAULT 0,
    btc_eth_leverage INTEGER DEFAULT 5,
    altcoin_leverage INTEGER DEFAULT 5,
    trading_symbols TEXT DEFAULT '',
    use_coin_pool BOOLEAN DEFAULT 0,
    use_oi_top BOOLEAN DEFAULT 0,
    created_at DATETIME DEFAULT CURRENT_TIMESTAMP,
    updated_at DATETIME DEFAULT CURRENT_TIMESTAMP,
    ...
)
```

**结论**：
- ✅ `initial_balance` 字段已存在，**无需修改 traders 表**
- ❌ 不添加 `original_deposit`、`total_realized_pnl`、`total_commission`（简化实现）
- ✅ 只需创建 `orders` 表

---

### Phase 1: 数据库迁移(30分钟)

#### 步骤1：修改 `config/database.go`

在 `InitDB()` 函数的表创建部分添加：

```go
// 在 config/database.go 的 InitDB() 函数中添加（约在 line 148 之后）

// 创建 orders 表（用于PNL统计和FIFO计算）
_, err = db.db.Exec(`
    CREATE TABLE IF NOT EXISTS orders (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        trader_id TEXT NOT NULL,

        -- 订单标识
        order_id TEXT,
        client_order_id TEXT UNIQUE,

        -- 订单基本信息
        symbol TEXT NOT NULL,
        side TEXT NOT NULL CHECK(side IN ('BUY', 'SELL')),
        position_side TEXT NOT NULL CHECK(position_side IN ('LONG', 'SHORT')),
        reduce_only BOOLEAN DEFAULT 0,

        -- 订单状态
        status TEXT NOT NULL DEFAULT 'FILLED'
            CHECK(status IN ('NEW', 'PARTIALLY_FILLED', 'FILLED', 'CANCELED', 'EXPIRED', 'REJECTED')),

        -- 价格和数量
        quantity REAL NOT NULL,
        filled_quantity REAL DEFAULT 0,
        avg_price REAL,

        -- 核心字段: FIFO跟踪
        remaining_quantity REAL DEFAULT 0,

        -- 盈亏和手续费
        realized_pnl REAL DEFAULT 0,
        commission REAL DEFAULT 0,

        -- 来源标记(仅用于审计)
        is_synthetic BOOLEAN DEFAULT 0,
        sync_source TEXT DEFAULT 'NORMAL'
            CHECK(sync_source IN ('NORMAL', 'EXCHANGE_SYNC', 'MANUAL_IMPORT')),

        -- 时间戳
        created_at DATETIME DEFAULT CURRENT_TIMESTAMP,
        updated_at DATETIME DEFAULT CURRENT_TIMESTAMP,

        -- 关联信息
        cycle_number INTEGER,

        -- 原始数据(JSON)
        exchange_response TEXT,

        FOREIGN KEY (trader_id) REFERENCES traders(id) ON DELETE CASCADE
    )
`)
if err != nil {
    return fmt.Errorf("create orders table failed: %v", err)
}

// 创建索引
indexes := []string{
    `CREATE INDEX IF NOT EXISTS idx_orders_trader_id ON orders(trader_id)`,
    `CREATE INDEX IF NOT EXISTS idx_orders_trader_symbol ON orders(trader_id, symbol, position_side)`,
    `CREATE INDEX IF NOT EXISTS idx_orders_remaining ON orders(trader_id, remaining_quantity)`,
    `CREATE INDEX IF NOT EXISTS idx_orders_status ON orders(status)`,
    `CREATE INDEX IF NOT EXISTS idx_orders_created_at ON orders(created_at)`,
}

for _, idx := range indexes {
    if _, err := db.db.Exec(idx); err != nil {
        log.Printf("⚠️ 创建索引失败 (可忽略): %v", err)
    }
}

log.Println("✓ orders 表创建成功")
```

#### 步骤2：验证数据库迁移

重启程序后，检查表是否创建成功：

```bash
# 查看数据库文件
sqlite3 ./data/nofx.db

# 验证 orders 表
sqlite> .schema orders
sqlite> SELECT COUNT(*) FROM orders;
sqlite> .quit
```

### Phase 2: 代码改造(1.5天)

**AutoTrader层 (10小时)**:
1. ✅ 实现 `syncPositions()` - 仓位同步(3小时)
2. ✅ 实现 `createSyntheticOrder()` - 虚拟订单(1小时)
3. ✅ 实现 `setInitialBalance()` - 设置初始余额(0.5小时)
4. ✅ 修改 `executeCloseLong()` - 使用事务(2小时)
5. ✅ 实现 `calculateRealizedPnLInTx()` - FIFO匹配(2小时)
6. ✅ 修改 `GetAccountInfo()` - 双收益率(1小时)
7. ✅ 集成到启动流程(1小时)
8. ✅ 实现告警机制(1小时)
9. ✅ 实现错误重试(1小时)

**API层 (1.5小时)**:

#### API修复1: handleCreateTrader (api/server.go:534-604) - 1小时 ⚠️ 重要

**问题**：使用 `totalEquity` 而不是 `walletBalance`

**修复步骤**：

```go
// 找到 api/server.go 第 586-604 行的余额提取代码
// ❌ 删除这段错误代码：
totalWalletBalance := 0.0
totalUnrealizedProfit := 0.0

if wallet, ok := balanceInfo["totalWalletBalance"].(float64); ok {
    totalWalletBalance = wallet
}
if unrealized, ok := balanceInfo["totalUnrealizedProfit"].(float64); ok {
    totalUnrealizedProfit = unrealized
}

// Total equity = wallet balance + unrealized P&L
totalEquity := totalWalletBalance + totalUnrealizedProfit
if totalEquity > 0 {
    actualBalance = totalEquity  // ❌ 错误！
}

// ✅ 替换为正确代码：
totalWalletBalance := 0.0

if wallet, ok := balanceInfo["totalWalletBalance"].(float64); ok {
    totalWalletBalance = wallet
}

// ✅ 使用 walletBalance 而不是 totalEquity
if totalWalletBalance > 0 {
    actualBalance = totalWalletBalance
    log.Printf("✓ 从交易所查询到钱包余额: %.2f USDT", totalWalletBalance)
}
```

**验证**：
```bash
# 创建trader时有仓位，检查日志
# 应该显示: "钱包余额: 95.00" 而不是 "100.00"
```

#### API修复2: handleEquityHistory (api/server.go:1558-1562) - 0.5小时

**问题**：使用第一条记录的equity作为fallback

**修复步骤**：

```go
// 找到 api/server.go 第 1558-1562 行
// ❌ 删除这段错误的fallback逻辑：
if initialBalance == 0 && len(records) > 0 {
    // 第一条记录的equity作为初始余额
    initialBalance = records[0].AccountState.TotalBalance + records[0].AccountState.TotalUnrealizedProfit
}

// ✅ 删除即可，不需要替换
// 保留下面的错误处理：
if initialBalance == 0 {
    c.JSON(http.StatusInternalServerError, gin.H{
        "error": "无法获取初始余额，请确保交易员已正确初始化",
    })
    return
}
```

**验证**：
```bash
# 查询历史收益，检查totalPnL是否基于正确的initial_balance计算
GET /api/equity-history?trader_id=xxx
```

#### API修复3: handleSyncBalance - ⚠️ 暂不实现

此功能暂不实现，保留现有代码不修改。

### Phase 3: 测试(1天)

**单元测试**:
1. ✅ 创建trader，无仓位 - initial_balance = walletBalance
2. ✅ 创建trader，有仓位 - initial_balance = walletBalance (不是equity)
3. ✅ 重启trader - initial_balance 保持不变
4. ✅ 运行时手动开仓 - 创建虚拟订单
5. ✅ 部分平仓测试 - FIFO 正确匹配
6. ✅ 对账测试 - 验证所有不变式

**API测试**:
1. ✅ POST /traders - 创建时initial_balance正确（有/无仓位）
2. ✅ GET /equity-history - 盈亏计算正确
3. ✅ GET /account - Equity公式验证

**集成测试**:
1. ✅ 完整流程 - 创建→开仓→平仓→重启→恢复
2. ✅ 并发测试 - 多trader同时运行
3. ✅ 异常恢复 - 网络中断、数据库故障

### Phase 4: 上线(0.5天)
1. 数据库迁移
2. 灰度发布
3. 监控验证

**总计: 2天完成**

---

## 📊 数据查询示例

### 查看虚拟订单(审计用)
```sql
SELECT
    symbol,
    position_side,
    quantity,
    avg_price,
    remaining_quantity,
    sync_source,
    created_at
FROM orders
WHERE trader_id = 'xxx'
  AND is_synthetic = TRUE
ORDER BY created_at DESC;
```

### 统计订单来源分布
```sql
SELECT
    sync_source,
    COUNT(*) as count,
    SUM(remaining_quantity * avg_price) as total_value
FROM orders
WHERE trader_id = 'xxx'
  AND reduce_only = FALSE
  AND remaining_quantity > 0
GROUP BY sync_source;

-- 结果示例:
-- sync_source      | count | total_value
-- NORMAL          | 50    | 5000.00
-- EXCHANGE_SYNC   | 2     | 500.00   ← 创建时的仓位
-- MANUAL_IMPORT   | 1     | 100.00   ← 用户手动开仓
```

### 对账查询
```sql
SELECT
    t.id,
    t.initial_balance,
    t.total_realized_pnl as cached_pnl,
    COALESCE(SUM(o.realized_pnl), 0) as calculated_pnl,
    t.total_realized_pnl - COALESCE(SUM(o.realized_pnl), 0) as diff
FROM traders t
LEFT JOIN orders o ON t.id = o.trader_id AND o.reduce_only = TRUE AND o.status = 'FILLED'
GROUP BY t.id
HAVING ABS(diff) > 0.01;
```

---

## 🔐 核心不变式(用于验证)

```go
// ===== 不变式1: Equity公式 =====
totalEquity == initialBalance + realizedPnL + unrealizedPnL

// ===== 不变式2: 数据库一致性 =====
traders.total_realized_pnl == SUM(orders.realized_pnl WHERE reduce_only = TRUE AND status = 'FILLED')

// ===== 不变式3: 仓位数量一致性 =====
exchangeAPI.position.quantity == SUM(orders.remaining_quantity WHERE reduce_only = FALSE)

// ===== 不变式4: Equity对账 =====
Abs(totalEquity - exchangeEquity) < 0.1 USDT

// ===== 不变式5: 统一处理 =====
// 平仓逻辑不依赖 is_synthetic 字段
// 查询时不过滤 is_synthetic
```

---

## ✅ 实施 Checklist

### Phase 1: 数据库迁移 (30分钟)
- [ ] 修改 `config/database.go` - 添加 orders 表创建代码
- [ ] 创建索引（5个索引）
- [ ] 重启程序，验证表创建成功
- [ ] 使用 sqlite3 命令验证表结构

### Phase 2: API层改动（1.5小时）- 立即修复
- [ ] **修复 `handleCreateTrader()`** (api/server.go:586-604)
  - [ ] 删除 `totalUnrealizedProfit` 变量
  - [ ] 删除 `totalEquity` 计算
  - [ ] 使用 `totalWalletBalance` 而不是 `totalEquity`
  - [ ] 添加日志输出确认使用正确的值
  - [ ] 测试：创建有仓位的trader，验证initial_balance正确
- [ ] **修复 `handleEquityHistory()`** (api/server.go:1558-1562)
  - [ ] 删除 lines 1558-1562 的 fallback 逻辑
  - [ ] 保留错误处理（无法获取时返回错误）
  - [ ] 测试：查询历史收益，验证totalPnL计算正确
- [ ] ~~handleSyncBalance()~~ - 暂不实现

### Phase 3: AutoTrader层核心功能（10小时）- 新功能开发
- [ ] 创建数据模型
  - [ ] 定义 Order 结构体
  - [ ] 定义 Position 结构体
  - [ ] 添加数据库访问方法
- [ ] 仓位同步机制
  - [ ] 实现 `syncPositions()` - 仓位同步
  - [ ] 实现 `getExchangePositions()` - 从交易所获取
  - [ ] 实现 `getPositionsFromDB()` - 从orders表计算
  - [ ] 实现 `findOrphanPositions()` - 发现差异
  - [ ] 实现 `createSyntheticOrder()` - 创建虚拟订单
  - [ ] 实现 `setInitialBalance()` - 设置初始余额
- [ ] FIFO盈亏计算
  - [ ] 实现 `calculateRealizedPnLInTx()` - FIFO匹配
  - [ ] 修改 `executeCloseLong()` - 使用事务
  - [ ] 修改 `executeCloseShort()` - 使用事务
  - [ ] 修改 `executeOpenLong()` - 记录订单
  - [ ] 修改 `executeOpenShort()` - 记录订单
- [ ] 启动和恢复
  - [ ] 修改 `Initialize()` - 集成仓位同步
  - [ ] 实现 `restoreFromDB()` - 严格对账
  - [ ] 实现告警机制 - 孤儿仓位告警
  - [ ] 实现错误重试 - 订单记录失败重试
- [ ] 账户信息
  - [ ] 修改 `GetAccountInfo()` - 添加PnL字段
  - [ ] 修改 `GetStatus()` - 返回initial_balance

### Phase 4: 测试验证（1天）

**API层测试**（立即执行）:
- [ ] 测试 `handleCreateTrader()` 修复
  - [ ] 创建无仓位trader - initial_balance = walletBalance
  - [ ] 创建有仓位trader - initial_balance = walletBalance (不是equity)
  - [ ] 检查日志输出是否正确
- [ ] 测试 `handleEquityHistory()` 修复
  - [ ] 查询历史收益 - totalPnL 基于正确的 initial_balance
  - [ ] 验证不再使用第一条记录的 fallback

**核心功能测试**（新功能开发完成后）:
- [ ] 仓位同步测试
  - [ ] 创建trader，无仓位
  - [ ] 创建trader，有仓位（自动创建虚拟订单）
  - [ ] 运行时手动开仓（创建虚拟订单）
  - [ ] 重启trader（initial_balance保持不变）
- [ ] FIFO盈亏测试
  - [ ] 完整开仓→平仓流程
  - [ ] 部分平仓测试（FIFO正确匹配）
  - [ ] 多次部分平仓测试
  - [ ] remaining_quantity 正确更新
- [ ] 对账测试
  - [ ] 验证不变式1：Equity = InitialBalance + RealizedPnL + UnrealizedPnL
  - [ ] 验证不变式2：traders.total_realized_pnl = SUM(orders.realized_pnl)
  - [ ] 验证不变式3：仓位数量一致性
  - [ ] 验证不变式4：Equity 对账（误差 < 0.1 USDT）
- [ ] 并发测试
  - [ ] 多trader同时运行
  - [ ] 同时开仓/平仓操作
- [ ] 异常恢复测试
  - [ ] 网络中断恢复
  - [ ] 数据库事务回滚
  - [ ] 订单记录失败重试

### Phase 5: 部署上线（0.5天）
- [ ] 数据库备份
- [ ] 代码部署
- [ ] 验证 orders 表创建成功
- [ ] 监控验证（检查日志）
- [ ] 灰度发布（先用一个test trader测试）

---

## 🚦 快速开始（建议执行顺序）

### 第一步：立即修复API层（30分钟）⚠️ 高优先级

这两个修复可以立即执行，不依赖其他功能：

1. **修复 handleCreateTrader** (api/server.go:586-604)
   ```bash
   # 删除 totalUnrealizedProfit 和 totalEquity
   # 使用 totalWalletBalance 而不是 totalEquity
   ```

2. **修复 handleEquityHistory** (api/server.go:1558-1562)
   ```bash
   # 删除 lines 1558-1562 的 fallback 逻辑
   ```

3. **测试验证**
   ```bash
   # 创建有仓位的trader，检查initial_balance是否正确
   # 查询历史收益，检查totalPnL计算是否正确
   ```

### 第二步：数据库迁移（30分钟）

1. **修改 config/database.go**
   - 在 InitDB() 函数中添加 orders 表创建代码
   - 创建 5 个索引

2. **重启程序**
   ```bash
   # 重启后会自动创建 orders 表
   ```

3. **验证**
   ```bash
   sqlite3 ./data/nofx.db
   sqlite> .schema orders
   sqlite> .quit
   ```

### 第三步：核心功能开发（1.5天）

按照 Phase 3 的 checklist 依次实现：
1. 创建数据模型
2. 仓位同步机制
3. FIFO盈亏计算
4. 启动和恢复
5. 账户信息

### 第四步：测试验证（1天）

执行 Phase 4 的所有测试用例。

### 总计时间估算

| 阶段 | 时间 | 说明 |
|------|------|------|
| API层修复 | 0.5天 | 立即执行 |
| 数据库迁移 | 0.5小时 | 简单 |
| 核心功能开发 | 1.5天 | 主要工作量 |
| 测试验证 | 1天 | 重要 |
| **总计** | **约3天** | - |

---

## 📝 文档维护规范

### 变更记录

#### v2.2 (2025-11-11)
- 🌟 **重大改进**: 统一处理原则
  - 通过虚拟订单机制,所有仓位统一处理
  - 后续操作不区分订单来源,代码简化50%
- ✅ **完善**: InitialBalance 定义
  - 详细说明创建trader时如何计算initial_balance
  - 支持 initial_balance (系统基准,用于Equity计算)
  - 支持 original_deposit (用户充值,可选,用于展示)
  - 支持双收益率展示
  - 明确说明为什么不是 `walletBalance - unrealizedPnL`
- ✅ **新增**: 仓位同步机制
  - 启动时自动同步
  - 识别孤儿仓位并告警
  - 创建虚拟订单补齐记录
- 🔧 **API层改动**:
  - 修复 handleCreateTrader 使用 totalEquity 的错误（应该用 walletBalance）
  - 修复 handleEquityHistory 的错误fallback逻辑
  - handleSyncBalance 暂不实现（设计上不应该改变initial_balance）
- 📝 **文档**: 梳理8大核心原则
- 📝 **文档**: 新增"InitialBalance的设定"专门章节
- 📝 **文档**: 新增"API层改动"章节
- 📝 **文档**: 更新实施时间为2天

#### v2.1 (2025-11-11)
- 🔴 修复平仓盈亏计算逻辑(添加remaining_quantity)
- 🔴 修复数据一致性风险(使用事务)
- 🟡 完善错误处理和重试机制
- ❌ **已废弃** - 逻辑复杂,多处if判断

#### v2.0 (2025-11-10)
- ✅ 初始版本
- ❌ **已废弃** - 存在关键缺陷

---

## 📞 联系与反馈

如果在实施过程中遇到问题或有改进建议,请:
1. 创建 GitHub Issue 讨论
2. 更新本文档的相关章节
3. 记录到变更日志中

**最后更新**: 2025-11-11
**文档状态**: ✅ 最终方案,待实施
