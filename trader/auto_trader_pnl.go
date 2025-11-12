package trader

import (
	"encoding/json"
	"fmt"
	"log"
	"math"
	"nofx/config"
	"strconv"
	"time"
)

// ===== PNL 系统 - 仓位同步机制 =====

// syncPositions 仓位同步 - 发现并补齐虚拟订单
func (at *AutoTrader) syncPositions(isCreation bool) error {
	log.Printf("🔄 [%s] 开始仓位同步 (isCreation=%v)", at.name, isCreation)

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

	// 3. 对比找出孤儿仓位
	orphans := at.findOrphanPositions(exchangePositions, dbPositions)

	if len(orphans) == 0 {
		log.Printf("✓ [%s] 仓位同步完成，无孤儿仓位", at.name)
		return nil
	}

	// 4. 发现孤儿仓位 - 告警
	log.Printf("⚠️ [%s] 发现 %d 个孤儿仓位:", at.name, len(orphans))
	for _, orphan := range orphans {
		log.Printf("  - %s %s: qty=%.4f, entryPrice=%.2f",
			orphan.Symbol, orphan.Side, orphan.Quantity, orphan.EntryPrice)
	}

	// 5. 处理孤儿仓位
	if isCreation {
		return at.handleOrphanPositionsOnCreation(orphans)
	} else {
		return at.handleOrphanPositionsOnRuntime(orphans)
	}
}

// getExchangePositions 从交易所获取持仓
func (at *AutoTrader) getExchangePositions() ([]Position, error) {
	resp, err := at.trader.GetPositions()
	if err != nil {
		return nil, err
	}

	var positions []Position
	for _, p := range resp {
		qty := getFloat64Field(p, "positionAmt")
		if math.Abs(qty) < 0.00001 {
			continue // 跳过空仓
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

// getPositionsFromDB 从 orders 表计算应有持仓
func (at *AutoTrader) getPositionsFromDB() (map[string]Position, error) {
	rows, err := at.database.PnLQueryPositions(at.id)
	if err != nil {
		return nil, err
	}

	positions := make(map[string]Position)
	for _, row := range rows {
		key := row.Symbol + "_" + row.Side
		positions[key] = Position{
			Symbol:     row.Symbol,
			Side:       row.Side,
			Quantity:   row.Quantity,
			EntryPrice: row.EntryPrice,
		}
	}

	return positions, nil
}

// findOrphanPositions 找出孤儿仓位
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
		} else if math.Abs(exPos.Quantity-dbP.Quantity) > 0.00001 {
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

// handleOrphanPositionsOnCreation 处理创建时的孤儿仓位
// ✅ initial_balance 已在 API 创建时设置，此方法只创建虚拟订单
func (at *AutoTrader) handleOrphanPositionsOnCreation(orphans []Position) error {
	// 转换为 PnLVirtualOrderInfo 类型
	virtualOrders := make([]config.PnLVirtualOrderInfo, len(orphans))
	for i, orphan := range orphans {
		virtualOrders[i] = config.PnLVirtualOrderInfo{
			Symbol:     orphan.Symbol,
			Side:       orphan.Side,
			Quantity:   orphan.Quantity,
			EntryPrice: orphan.EntryPrice,
			Source:     "EXCHANGE_SYNC",
		}
	}

	// ✅ 不再传递 walletBalance，不再修改 initial_balance
	if err := at.database.PnLCreateVirtualOrdersOnCreation(at.id, virtualOrders); err != nil {
		return err
	}

	// ✅ 不覆盖 at.initialBalance，保持从数据库加载的值
	log.Printf("✓ [%s] 创建时有仓位: initial_balance=%.2f (从数据库加载), 已创建 %d 个虚拟订单",
		at.name, at.initialBalance, len(orphans))

	return nil
}

// handleOrphanPositionsOnRuntime 处理运行时的孤儿仓位（用户手动开仓）
func (at *AutoTrader) handleOrphanPositionsOnRuntime(orphans []Position) error {
	log.Printf("🚨 [%s] CRITICAL: 运行时发现孤儿仓位!", at.name)
	log.Printf("   可能原因: 用户手动开仓")
	log.Printf("   操作: 创建虚拟订单并接管")

	// 转换为 PnLVirtualOrderInfo 类型
	virtualOrders := make([]config.PnLVirtualOrderInfo, len(orphans))
	for i, orphan := range orphans {
		virtualOrders[i] = config.PnLVirtualOrderInfo{
			Symbol:     orphan.Symbol,
			Side:       orphan.Side,
			Quantity:   orphan.Quantity,
			EntryPrice: orphan.EntryPrice,
			Source:     "MANUAL_IMPORT",
		}
	}

	// 使用数据库接口方法
	if err := at.database.PnLCreateVirtualOrdersOnRuntime(at.id, virtualOrders); err != nil {
		return err
	}

	log.Printf("✓ [%s] 已创建 %d 个虚拟订单，仓位已接管", at.name, len(orphans))
	return nil
}

// ===== PNL 系统 - 辅助函数 =====

// getStringField 安全地从 map 中提取字符串字段
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

// getFloat64Field 安全地从 map 中提取 float64 字段
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

// getBoolField 安全地从 map 中提取 bool 字段
func getBoolField(m map[string]interface{}, key string) bool {
	if v, ok := m[key]; ok {
		if b, ok := v.(bool); ok {
			return b
		}
	}
	return false
}

// toJSON 将对象转为 JSON 字符串
func toJSON(v interface{}) string {
	b, _ := json.Marshal(v)
	return string(b)
}

// ===== PNL 系统 - 辅助函数 =====

// calculateCommissionInUSDT 转换手续费为 USDT
func (at *AutoTrader) calculateCommissionInUSDT(order map[string]interface{}) (float64, error) {
	commission := getFloat64Field(order, "commission")
	asset := getStringField(order, "commissionAsset")

	if asset == "" || asset == "USDT" {
		return commission, nil
	}

	// TODO: 如果手续费不是 USDT，需要实现价格查询转换
	// 暂时返回 0，避免阻塞
	log.Printf("⚠️ 手续费资产为 %s，暂未实现转换为 USDT", asset)
	return 0, nil
}

// recordOrderWithRetry 带重试的订单记录
func (at *AutoTrader) recordOrderWithRetry(order map[string]interface{}, symbol, positionSide string, reduceOnly bool) error {
	var lastErr error
	for i := 0; i < 3; i++ {
		err := at.recordOrder(order, symbol, positionSide, reduceOnly)
		if err == nil {
			return nil
		}
		lastErr = err
		time.Sleep(time.Second * time.Duration(1<<i))
	}
	return fmt.Errorf("record order failed after retries: %w", lastErr)
}

// recordOrder 记录订单到数据库
func (at *AutoTrader) recordOrder(order map[string]interface{}, symbol, positionSide string, reduceOnly bool) error {
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

	// 从订单响应中提取 side
	side := getStringField(order, "side")
	if side == "" {
		// 如果订单中没有 side，根据 reduceOnly 推断
		if reduceOnly {
			side = "SELL" // 平仓通常是卖出
		} else {
			side = "BUY" // 开仓通常是买入
		}
	}

	commission, err := at.calculateCommissionInUSDT(order)
	if err != nil {
		log.Printf("⚠️ [%s] 手续费计算失败: %v", at.name, err)
		commission = 0
	}

	status := getStringField(order, "status")
	if status == "" {
		status = "FILLED"
	}

	// 使用数据库接口方法
	orderInfo := config.PnLOpenOrderInfo{
		OrderID:          orderID,
		ClientOrderID:    clientOrderID,
		Symbol:           symbol,
		Side:             side,
		PositionSide:     positionSide,
		ReduceOnly:       reduceOnly,
		Status:           status,
		ExecutedQty:      executedQty,
		AvgPrice:         avgPrice,
		Commission:       commission,
		CycleNumber:      at.cycleNumber,
		ExchangeResponse: order,
	}

	return at.database.PnLRecordOpenOrder(at.id, orderInfo)
}

// recordCloseOrderWithPnL 记录平仓订单并计算实现盈亏（事务处理）
func (at *AutoTrader) recordCloseOrderWithPnL(order map[string]interface{}, symbol, positionSide string) error {
	// 提取订单信息
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

	side := getStringField(order, "side")
	if side == "" {
		// 平仓通常是卖出
		side = "SELL"
	}

	commission, err := at.calculateCommissionInUSDT(order)
	if err != nil {
		log.Printf("⚠️ [%s] 手续费计算失败: %v", at.name, err)
		commission = 0
	}

	status := getStringField(order, "status")
	if status == "" {
		status = "FILLED"
	}

	// 使用数据库接口方法
	orderInfo := config.PnLCloseOrderInfo{
		OrderID:          orderID,
		ClientOrderID:    clientOrderID,
		Symbol:           symbol,
		Side:             side,
		PositionSide:     positionSide,
		Status:           status,
		ExecutedQty:      executedQty,
		AvgPrice:         avgPrice,
		Commission:       commission,
		CycleNumber:      at.cycleNumber,
		ExchangeResponse: order,
	}

	realizedPnL, totalCommission, err := at.database.PnLRecordCloseOrder(at.id, orderInfo, at.name, log.Printf)
	if err != nil {
		return err
	}

	// 更新内存状态
	at.pnlMutex.Lock()
	at.totalRealizedPnL += realizedPnL
	at.totalCommission += totalCommission
	at.pnlMutex.Unlock()

	log.Printf("  ✓ [%s] 累计盈亏: %.2f (本次: %.2f, 手续费: %.2f)",
		at.name, at.totalRealizedPnL, realizedPnL, totalCommission)

	return nil

	return fmt.Errorf("database does not support PnL operations")
}

// ===== PNL 系统 - 启动和恢复 =====

// restoreFromDB 从数据库恢复 PNL 状态
func (at *AutoTrader) restoreFromDB() error {
	// 使用数据库接口方法
	totalRealizedPnL, totalCommission, err := at.database.PnLRestoreState(at.id)
	if err != nil {
		return fmt.Errorf("restore failed: %w", err)
	}

	at.pnlMutex.Lock()
	at.totalRealizedPnL = totalRealizedPnL
	at.totalCommission = totalCommission
	at.pnlMutex.Unlock()

	log.Printf("✓ [%s] PNL 状态恢复: RealizedPnL=%.2f, Commission=%.2f",
		at.name, totalRealizedPnL, totalCommission)

	return nil
}

// verifyAccountBalance 验证账户余额对账
func (at *AutoTrader) verifyAccountBalance() error {
	balance, err := at.trader.GetBalance()
	if err != nil {
		return err
	}

	walletBalance := getFloat64Field(balance, "totalWalletBalance")
	unrealizedPnL := getFloat64Field(balance, "totalUnrealizedProfit")

	at.pnlMutex.RLock()
	realizedPnL := at.totalRealizedPnL
	initialBalance := at.initialBalance
	at.pnlMutex.RUnlock()

	// 计算净值
	calculatedEquity := initialBalance + realizedPnL + unrealizedPnL
	exchangeEquity := walletBalance + unrealizedPnL

	diff := math.Abs(calculatedEquity - exchangeEquity)
	if diff > 0.1 {
		log.Printf("⚠️ [%s] Equity mismatch: Calculated=%.2f, Exchange=%.2f, Diff=%.2f",
			at.name, calculatedEquity, exchangeEquity, diff)
		return fmt.Errorf("equity mismatch: %.2f USDT", diff)
	}

	log.Printf("✓ [%s] 账户对账通过: Equity=%.2f", at.name, calculatedEquity)
	return nil
}

// ===== PNL 系统 - 初始化 =====

// Initialize 初始化 PNL 系统（在 trader 启动时调用）
func (at *AutoTrader) Initialize(isNewTrader bool) error {
	log.Printf("🔄 [%s] 初始化 PNL 系统...", at.name)

	// 1. 如果不是新创建的 trader，从数据库恢复状态
	if !isNewTrader {
		if err := at.restoreFromDB(); err != nil {
			return fmt.Errorf("恢复 PNL 状态失败: %w", err)
		}
	}

	// 2. 执行仓位同步（关键步骤）
	if err := at.syncPositions(isNewTrader); err != nil {
		return fmt.Errorf("仓位同步失败: %w", err)
	}

	// 3. 验证对账
	if err := at.verifyAccountBalance(); err != nil {
		log.Printf("⚠️ [%s] 对账验证发现差异: %v", at.name, err)
	}

	log.Printf("✓ [%s] PNL 系统初始化完成", at.name)
	return nil
}
