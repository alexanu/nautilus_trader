# -------------------------------------------------------------------------------------------------
#  Copyright (C) 2015-2020 Nautech Systems Pty Ltd. All rights reserved.
#  https://nautechsystems.io
#
#  Licensed under the GNU Lesser General Public License Version 3.0 (the "License");
#  You may not use this file except in compliance with the License.
#  You may obtain a copy of the License at https://www.gnu.org/licenses/lgpl-3.0.en.html
#
#  Unless required by applicable law or agreed to in writing, software
#  distributed under the License is distributed on an "AS IS" BASIS,
#  WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
#  See the License for the specific language governing permissions and
#  limitations under the License.
# -------------------------------------------------------------------------------------------------

# cython: boundscheck=False
# cython: wraparound=False

import datetime as dt
import pytz
from cpython.datetime cimport datetime, timedelta

from nautilus_trader.core.correctness cimport Condition
from nautilus_trader.core.types cimport ValidString
from nautilus_trader.model.c_enums.price_type cimport PriceType
from nautilus_trader.model.c_enums.order_type cimport OrderType
from nautilus_trader.model.c_enums.order_side cimport OrderSide
from nautilus_trader.model.c_enums.order_state cimport OrderState
from nautilus_trader.model.c_enums.currency cimport Currency
from nautilus_trader.model.c_enums.security_type cimport SecurityType
from nautilus_trader.model.c_enums.market_position cimport MarketPosition, market_position_to_string
from nautilus_trader.model.identifiers cimport Symbol, OrderIdBroker
from nautilus_trader.model.currency cimport ExchangeRateCalculator
from nautilus_trader.model.objects cimport Decimal, Price, Tick, Money, Instrument, Quantity
from nautilus_trader.model.order cimport Order
from nautilus_trader.model.position cimport Position
from nautilus_trader.model.events cimport AccountStateEvent, OrderFillEvent, OrderSubmitted
from nautilus_trader.model.events cimport OrderAccepted, OrderRejected, OrderWorking, OrderExpired
from nautilus_trader.model.events cimport OrderModified, OrderCancelled, OrderCancelReject
from nautilus_trader.model.events cimport OrderFilled
from nautilus_trader.model.identifiers cimport OrderId, ExecutionId, PositionIdBroker
from nautilus_trader.model.commands cimport AccountInquiry, SubmitOrder, SubmitAtomicOrder
from nautilus_trader.model.commands cimport ModifyOrder,CancelOrder
from nautilus_trader.common.account cimport Account
from nautilus_trader.common.brokerage cimport CommissionCalculator, RolloverInterestCalculator
from nautilus_trader.common.clock cimport TestClock
from nautilus_trader.common.guid cimport TestGuidFactory
from nautilus_trader.common.logging cimport Logger
from nautilus_trader.common.execution cimport ExecutionEngine, ExecutionClient
from nautilus_trader.backtest.config cimport BacktestConfig
from nautilus_trader.backtest.models cimport FillModel

# Stop order types
cdef set STOP_ORDER_TYPES = {
    OrderType.STOP,
    OrderType.STOP_LIMIT,
    OrderType.MIT}


cdef class BacktestExecClient(ExecutionClient):
    """
    Provides an execution client for the BacktestEngine.
    """

    def __init__(self,
                 ExecutionEngine exec_engine not None,
                 dict instruments not None: {Symbol, Instrument},
                 BacktestConfig config not None,
                 FillModel fill_model not None,
                 TestClock clock not None,
                 TestGuidFactory guid_factory not None,
                 Logger logger not None):
        """
        Initializes a new instance of the BacktestExecClient class.

        :param exec_engine: The execution engine for the backtest.
        :param instruments: The instruments needed for the backtest.
        :param config: The backtest configuration.
        :param fill_model: The fill model for the backtest.
        :param clock: The clock for the component.
        :param clock: The GUID factory for the component.
        :param logger: The logger for the component.
        :raises ValueError: If the instruments list contains a type other than Instrument.
        """
        Condition.dict_types(instruments, Symbol, Instrument, 'instruments')
        super().__init__(exec_engine, logger)

        self._clock = clock
        self._guid_factory = guid_factory

        self.instruments = instruments

        self.day_number = 0
        self.rollover_time = None
        self.rollover_applied = False
        self.frozen_account = config.frozen_account
        self.starting_capital = config.starting_capital
        self.account_currency = config.account_currency
        self.account_capital = config.starting_capital
        self.account_cash_start_day = config.starting_capital
        self.account_cash_activity_day = Money(0, self.account_currency)

        self._account = Account(self.reset_account_event())
        self.exec_db = exec_engine.database
        self.exchange_calculator = ExchangeRateCalculator()
        self.commission_calculator = CommissionCalculator(default_rate_bp=config.commission_rate_bp)
        self.rollover_calculator = RolloverInterestCalculator(config.short_term_interest_csv_path)
        self.rollover_spread = 0.0 # Bank + Broker spread markup
        self.total_commissions = Money(0, self.account_currency)
        self.total_rollover = Money(0, self.account_currency)
        self.fill_model = fill_model

        self._market = {}               # type: {Symbol, Tick}
        self._working_orders = {}       # type: {OrderId, Order}
        self._atomic_child_orders = {}  # type: {OrderId, [Order]}
        self._oco_orders = {}           # type: {OrderId, OrderId}

        self._set_slippages()
        self._set_min_distances()

    cdef void _set_slippages(self) except *:
        cdef dict slippage_index = {}  # type: {Symbol, Decimal}

        for symbol, instrument in self.instruments.items():
            slippage_index[symbol] = instrument.tick_size

        self._slippages = slippage_index

    cdef void _set_min_distances(self) except *:
        cdef dict min_stops = {}   # type: {Symbol, Decimal}
        cdef dict min_limits = {}  # type: {Symbol, Decimal}

        for symbol, instrument in self.instruments.items():
            min_stops[symbol] = Decimal(
                instrument.tick_size * instrument.min_stop_distance,
                instrument.price_precision)

            min_limits[symbol] = Decimal(
                instrument.tick_size * instrument.min_limit_distance,
                instrument.price_precision)

        self._min_stops = min_stops
        self._min_limits = min_limits

    cdef dict _build_current_bid_rates(self):
        """
        Return the current currency bid rates in the markets.
        
        :return: Dict[Symbol, double].
        """
        cdef Symbol symbol
        cdef Tick tick
        return {symbol.code: tick.bid.as_double() for symbol, tick in self._market.items()}

    cdef dict _build_current_ask_rates(self):
        """
        Return the current currency ask rates in the markets.
        
        :return: Dict[Symbol, double].
        """
        cdef Symbol symbol
        cdef Tick tick
        return {symbol.code: tick.ask.as_double() for symbol, tick in self._market.items()}

    cpdef void check_residuals(self) except *:
        """
        Check for any residual objects and log warnings if any are found.
        """
        for order_list in self._atomic_child_orders.values():
            for order in order_list:
                self._log.warning(f"Residual child-order {order}")

        for order_id in self._oco_orders.values():
            self._log.warning(f"Residual OCO {order_id}")

    cpdef void reset(self) except *:
        """
        Return the client to its initial state preserving tick data.
        """
        self._log.debug(f"Resetting...")

        self._reset()
        self.day_number = 0
        self.account_capital = self.starting_capital
        self.account_cash_start_day = self.account_capital
        self.account_cash_activity_day = Money(0, self.account_currency)
        self.total_commissions = Money(0, self.account_currency)
        self.total_rollover = Money(0, self.account_currency)

        self._market = {}               # type: {Symbol, Tick}
        self._working_orders = {}       # type: {OrderId, Order}
        self._atomic_child_orders = {}  # type: {OrderId, [Order]}
        self._oco_orders = {}           # type: {OrderId, OrderId}

        self._log.info("Reset.")

    cpdef void dispose(self) except *:
        """
        TBD.
        """
        pass

    cdef AccountStateEvent reset_account_event(self):
        """
        Resets the account.
        """
        return AccountStateEvent(
            self._exec_engine.account_id,
            self.account_currency,
            self.starting_capital,
            self.starting_capital,
            Money(0, self.account_currency),
            Money(0, self.account_currency),
            Money(0, self.account_currency),
            Decimal.zero(),
            ValidString('N'),
            self._guid_factory.generate(),
            self._clock.time_now())

    cpdef datetime time_now(self):
        """
        Return the current time for the execution client.

        :return: datetime.
        """
        return self._clock.time_now()

    cpdef void connect(self) except *:
        """
        Connect to the execution service.
        """
        self._log.info("Connected.")
        # Do nothing else

    cpdef void disconnect(self) except *:
        """
        Disconnect from the execution service.
        """
        self._log.info("Disconnected.")
        # Do nothing else

    cpdef void change_fill_model(self, FillModel fill_model) except *:
        """
        Set the fill model to be the given model.
        
        :param fill_model: The fill model to set.
        """
        Condition.not_none(fill_model, 'fill_model')

        self.fill_model = fill_model

    cpdef void process_tick(self, Tick tick) except *:
        """
        Process the execution client with the given tick. Market dynamics are
        simulated against working orders.
        
        :param tick: The tick data to process with.
        """
        Condition.not_none(tick, 'tick')

        self._clock.set_time(tick.timestamp)
        self._market[tick.symbol] = tick

        cdef datetime time_now = self._clock.time_now()

        if self.day_number != time_now.day:
            # Set account statistics for new day
            self.day_number = time_now.day
            self.account_cash_start_day = self._account.cash_balance
            self.account_cash_activity_day = Money(0, self.account_currency)
            self.rollover_applied = False
            self.rollover_time = dt.datetime(
                time_now.year,
                time_now.month,
                time_now.day,
                17,
                0,
                0,
                0,
                tzinfo=pytz.timezone('US/Eastern')).astimezone(tz=pytz.utc) - timedelta(minutes=56)
            #  TODO: Why is this consistently 56 min out?

        # Check for and apply any rollover interest
        if not self.rollover_applied and time_now >= self.rollover_time:
            self.apply_rollover_interest(time_now, self.rollover_time.isoweekday())
            self.rollover_applied = True

        # Check for working orders
        if not self._working_orders:
            return

        # Simulate market
        cdef OrderId order_id
        cdef Order order
        cdef Instrument instrument
        for order in self._working_orders.copy().values():  # Copies list to avoid resize during loop
            if not order.symbol.equals(tick.symbol):
                continue  # Order is for a different symbol
            if order.state != OrderState.WORKING:
                continue  # Orders state has changed since the loop commenced

            instrument = self.instruments[order.symbol]

            # Check for order fill
            if order.side == OrderSide.BUY:
                if order.type in STOP_ORDER_TYPES:
                    if tick.ask.ge(order.price) or self._is_marginal_buy_stop_fill(order.price, tick):
                        del self._working_orders[order.id]  # Remove order from working orders
                        if self.fill_model.is_slipped():
                            self._fill_order(order, order.price.add(self._slippages[order.symbol]))
                        else:
                            self._fill_order(order, order.price)
                        continue  # Continue loop to next order
                elif order.type == OrderType.LIMIT:
                    if tick.ask.le(order.price) or self._is_marginal_buy_limit_fill(order.price, tick):
                        del self._working_orders[order.id]  # Remove order from working orders
                        if self.fill_model.is_slipped():
                            self._fill_order(order, order.price.add(self._slippages[order.symbol]))
                        else:
                            self._fill_order(order, order.price)
                        continue  # Continue loop to next order
            elif order.side == OrderSide.SELL:
                if order.type in STOP_ORDER_TYPES:
                    if tick.bid.le(order.price) or self._is_marginal_sell_stop_fill(order.price, tick):
                        del self._working_orders[order.id]  # Remove order from working orders
                        if self.fill_model.is_slipped():
                            self._fill_order(order, order.price.subtract(self._slippages[order.symbol]))
                        else:
                            self._fill_order(order, order.price)
                        continue  # Continue loop to next order
                elif order.type == OrderType.LIMIT:
                    if tick.bid.ge(order.price) or self._is_marginal_sell_limit_fill(order.price, tick):
                        del self._working_orders[order.id]  # Remove order from working orders
                        if self.fill_model.is_slipped():
                            self._fill_order(order, order.price.subtract(self._slippages[order.symbol]))
                        else:
                            self._fill_order(order, order.price)
                        continue  # Continue loop to next order

            # Check for order expiry
            if order.expire_time is not None and time_now >= order.expire_time:
                if order.id in self._working_orders:  # Order may have been removed since loop started
                    del self._working_orders[order.id]
                    self._expire_order(order)

    cpdef void adjust_account(self, OrderFillEvent event, Position position) except *:
        Condition.not_none(event, 'event')
        Condition.not_none(position, 'position')

        # Calculate commission
        cdef Instrument instrument = self.instruments[event.symbol]
        cdef double exchange_rate = self.exchange_calculator.get_rate(
            from_currency=instrument.quote_currency,
            to_currency=self._account.currency,
            price_type=PriceType.BID if event.order_side is OrderSide.SELL else PriceType.ASK,
            bid_rates=self._build_current_bid_rates(),
            ask_rates=self._build_current_ask_rates())

        cdef Money pnl = self.calculate_pnl(
            direction=position.market_position,
            open_price=position.average_open_price,
            close_price=event.average_price.as_double(),
            quantity=event.filled_quantity,
            exchange_rate=exchange_rate)

        cdef Money commission = self.commission_calculator.calculate(
            symbol=event.symbol,
            filled_quantity=event.filled_quantity,
            filled_price=event.average_price,
            exchange_rate=exchange_rate,
            currency=self.account_currency)

        self.total_commissions = self.total_commissions.subtract(commission)
        pnl = pnl.subtract(commission)

        cdef AccountStateEvent account_event
        if not self.frozen_account:
            self.account_capital = self.account_capital.add(pnl)
            self.account_cash_activity_day = self.account_cash_activity_day.add(pnl)

            account_event = AccountStateEvent(
                self._account.id,
                self._account.currency,
                self.account_capital,
                self.account_cash_start_day,
                self.account_cash_activity_day,
                margin_used_liquidation=Money(0, self.account_currency),
                margin_used_maintenance=Money(0, self.account_currency),
                margin_ratio=Decimal.zero(),
                margin_call_status=ValidString('N'),
                event_id=self._guid_factory.generate(),
                event_timestamp=self._clock.time_now())

            self._exec_engine.handle_event(account_event)

    cpdef Money calculate_pnl(
            self,
            MarketPosition direction,
            double open_price,
            double close_price,
            Quantity quantity,
            double exchange_rate):
        Condition.not_none(quantity, 'quantity')

        cdef double difference
        if direction == MarketPosition.LONG:
            difference = close_price - open_price
        elif direction == MarketPosition.SHORT:
            difference = open_price - close_price
        else:
            raise ValueError(f'Cannot calculate the pnl of a '
                             f'{market_position_to_string(direction)} direction.')

        return Money(difference * quantity.as_double() * exchange_rate, self.account_currency)

    cpdef void apply_rollover_interest(self, datetime timestamp, int iso_week_day) except *:
        Condition.not_none(timestamp, 'timestamp')

        # Apply rollover interest for all open positions
        if self.exec_db is None:
            self._log.error("Cannot apply rollover interest (no execution database registered).")
            return

        cdef dict open_positions = self.exec_db.get_positions_open()

        cdef Instrument instrument
        cdef Currency base_currency
        cdef double interest_rate
        cdef double exchange_rate
        cdef double rollover
        cdef double rollover_cumulative = 0.0
        cdef double mid_price
        cdef dict mid_prices = {}
        cdef Tick market
        for position in open_positions.values():
            instrument = self.instruments[position.symbol]
            if instrument.security_type == SecurityType.FOREX:
                mid_price = mid_prices.get(instrument.symbol, 0.0)
                if mid_price == 0.0:
                    market = self._market[instrument.symbol]
                    mid_price = (market.ask.as_double() + market.bid.as_double()) / 2.0
                    mid_prices[instrument.symbol] = mid_price
                interest_rate = self.rollover_calculator.calc_overnight_rate(
                    position.symbol,
                    timestamp)
                exchange_rate = self.exchange_calculator.get_rate(
                    from_currency=instrument.quote_currency,
                    to_currency=self._account.currency,
                    price_type=PriceType.MID,
                    bid_rates=self._build_current_bid_rates(),
                    ask_rates=self._build_current_ask_rates())
                rollover = mid_price * position.quantity.as_double() * interest_rate * exchange_rate
                # Apply any bank and broker spread markup (basis points)
                rollover_cumulative += rollover - (rollover * self.rollover_spread)

        if iso_week_day == 3: # Book triple for Wednesdays
            rollover_cumulative = rollover_cumulative * 3.0
        elif iso_week_day == 5: # Book triple for Fridays (holding over weekend)
            rollover_cumulative = rollover_cumulative * 3.0

        cdef Money rollover_final = Money(rollover_cumulative, self.account_currency)
        self.total_rollover = self.total_rollover.add(rollover_final)

        cdef AccountStateEvent account_event
        if not self.frozen_account:
            self.account_capital = self.account_capital.add(rollover_final)
            self.account_cash_activity_day = self.account_cash_activity_day.add(rollover_final)

            account_event = AccountStateEvent(
                self._account.id,
                self._account.currency,
                self.account_capital,
                self.account_cash_start_day,
                self.account_cash_activity_day,
                margin_used_liquidation=Money(0, self.account_currency),
                margin_used_maintenance=Money(0, self.account_currency),
                margin_ratio=Decimal.zero(),
                margin_call_status=ValidString('N'),
                event_id=self._guid_factory.generate(),
                event_timestamp=self._clock.time_now())

            self._exec_engine.handle_event(account_event)


# -- COMMAND EXECUTION -----------------------------------------------------------------------------

    cpdef void account_inquiry(self, AccountInquiry command) except *:
        Condition.not_none(command, 'command')

        # Generate event
        cdef AccountStateEvent event = AccountStateEvent(
            self._account.id,
            self._account.currency,
            self._account.cash_balance,
            self.account_cash_start_day,
            self.account_cash_activity_day,
            self._account.margin_used_liquidation,
            self._account.margin_used_maintenance,
            self._account.margin_ratio,
            self._account.margin_call_status,
            self._guid_factory.generate(),
            self._clock.time_now())

        self._exec_engine.handle_event(event)

    cpdef void submit_order(self, SubmitOrder command) except *:
        Condition.not_none(command, 'command')

        # Generate event
        cdef OrderSubmitted submitted = OrderSubmitted(
            command.account_id,
            command.order.id,
            self._clock.time_now(),
            self._guid_factory.generate(),
            self._clock.time_now())

        self._exec_engine.handle_event(submitted)
        self._process_order(command.order)

    cpdef void submit_atomic_order(self, SubmitAtomicOrder command) except *:
        Condition.not_none(command, 'command')

        cdef list atomic_orders = [command.atomic_order.stop_loss]
        if command.atomic_order.has_take_profit:
            atomic_orders.append(command.atomic_order.take_profit)
            self._oco_orders[command.atomic_order.take_profit.id] = command.atomic_order.stop_loss.id
            self._oco_orders[command.atomic_order.stop_loss.id] = command.atomic_order.take_profit.id

        self._atomic_child_orders[command.atomic_order.entry.id] = atomic_orders

        # Generate command
        cdef SubmitOrder submit_order = SubmitOrder(
            command.trader_id,
            command.account_id,
            command.strategy_id,
            command.position_id,
            command.atomic_order.entry,
            self._guid_factory.generate(),
            self._clock.time_now())

        self.submit_order(submit_order)

    cpdef void cancel_order(self, CancelOrder command) except *:
        Condition.not_none(command, 'command')

        if command.order_id not in self._working_orders:
            self._cancel_reject_order(command.order_id, 'cancel order', 'order not found')
            return  # Rejected the cancel order command

        cdef Order order = self._working_orders[command.order_id]

        # Generate event
        cdef OrderCancelled cancelled = OrderCancelled(
            command.account_id,
            order.id,
            self._clock.time_now(),
            self._guid_factory.generate(),
            self._clock.time_now())

        # Remove from working orders (checked it was in dictionary above)
        del self._working_orders[command.order_id]

        self._exec_engine.handle_event(cancelled)
        self._check_oco_order(command.order_id)

    cpdef void modify_order(self, ModifyOrder command) except *:
        Condition.not_none(command, 'command')

        if command.order_id not in self._working_orders:
            self._cancel_reject_order(command.order_id, 'modify order', 'order not found')
            return  # Rejected the modify order command

        cdef Order order = self._working_orders[command.order_id]
        cdef Instrument instrument = self.instruments[order.symbol]

        if command.modified_quantity.as_double() == 0.0:
            self._cancel_reject_order(
                order,
                'modify order',
                f'modified quantity {command.modified_quantity} invalid')
            return  # Cannot modify order

        if not self._check_valid_price(order, self._market[order.symbol], reject=True):
            return  # Cannot accept order

        # Generate event
        cdef OrderModified modified = OrderModified(
            command.account_id,
            order.id,
            order.id_broker,
            command.modified_quantity,
            command.modified_price,
            self._clock.time_now(),
            self._guid_factory.generate(),
            self._clock.time_now())

        self._exec_engine.handle_event(modified)


# -- EVENT HANDLING --------------------------------------------------------------------------------

    cdef bint _check_valid_price(self, Order order, Tick current_market, bint reject=True):
        # Check order price is valid and reject if not
        if order.side == OrderSide.BUY:
            if order.type in STOP_ORDER_TYPES:
                if order.price.lt(current_market.ask.add(self._min_stops[order.symbol])):
                    if reject:
                        self._reject_order(order, f'BUY STOP order price of {order.price} is too '
                                                  f'far from the market, ask={current_market.ask}')
                    return False  # Invalid price
            elif order.type == OrderType.LIMIT:
                if order.price.gt(current_market.bid.subtract(self._min_limits[order.symbol])):
                    if reject:
                        self._reject_order(order, f'BUY LIMIT order price of {order.price} is too '
                                                  f'far from the market, bid={current_market.bid}')
                    return False  # Invalid price
        elif order.side == OrderSide.SELL:
            if order.type in STOP_ORDER_TYPES:
                if order.price.gt(current_market.bid.subtract(self._min_stops[order.symbol])):
                    if reject:
                        self._reject_order(order, f'SELL STOP order price of {order.price} is too '
                                                  f'far from the market, bid={current_market.bid}')
                    return False  # Invalid price
            elif order.type == OrderType.LIMIT:
                if order.price.lt(current_market.ask.add(self._min_limits[order.symbol])):
                    if reject:
                        self._reject_order(order, f'SELL LIMIT order price of {order.price} is too '
                                                  f'far from the market, ask={current_market.ask}')
                    return False  # Invalid price

        return True  # Valid price

    cdef bint _is_marginal_buy_stop_fill(self, Price order_price, Tick current_market):
        return current_market.ask.eq(order_price) and self.fill_model.is_stop_filled()

    cdef bint _is_marginal_buy_limit_fill(self, Price order_price, Tick current_market):
        return current_market.ask.eq(order_price) and self.fill_model.is_limit_filled()

    cdef bint _is_marginal_sell_stop_fill(self, Price order_price, Tick current_market):
        return current_market.bid.eq(order_price) and self.fill_model.is_stop_filled()

    cdef bint _is_marginal_sell_limit_fill(self, Price order_price, Tick current_market):
        return current_market.bid.eq(order_price) and self.fill_model.is_limit_filled()

    cdef void _accept_order(self, Order order) except *:
        # Generate event
        cdef OrderAccepted accepted = OrderAccepted(
            self._account.id,
            order.id,
            OrderIdBroker('B' + order.id.value),
            order.label,
            self._clock.time_now(),
            self._guid_factory.generate(),
            self._clock.time_now())

        self._exec_engine.handle_event(accepted)

    cdef void _reject_order(self, Order order, str reason) except *:
        # Generate event
        cdef OrderRejected rejected = OrderRejected(
            self._account.id,
            order.id,
            self._clock.time_now(),
            ValidString(reason),
            self._guid_factory.generate(),
            self._clock.time_now())

        self._exec_engine.handle_event(rejected)
        self._check_oco_order(order.id)
        self._clean_up_child_orders(order.id)

    cdef void _cancel_reject_order(
            self,
            OrderId order_id,
            str response,
            str reason) except *:
        # Generate event
        cdef OrderCancelReject cancel_reject = OrderCancelReject(
            self._account.id,
            order_id,
            self._clock.time_now(),
            ValidString(response),
            ValidString(reason),
            self._guid_factory.generate(),
            self._clock.time_now())

        self._exec_engine.handle_event(cancel_reject)

    cdef void _expire_order(self, Order order) except *:
        # Generate event
        cdef OrderExpired expired = OrderExpired(
            self._account.id,
            order.id,
            order.expire_time,
            self._guid_factory.generate(),
            self._clock.time_now())

        self._exec_engine.handle_event(expired)

        cdef OrderId first_child_order_id
        cdef OrderId other_oco_order_id
        if order.id in self._atomic_child_orders:
            # Remove any unprocessed atomic child order OCO identifiers
            first_child_order_id = self._atomic_child_orders[order.id][0].id
            if first_child_order_id in self._oco_orders:
                other_oco_order_id = self._oco_orders[first_child_order_id]
                del self._oco_orders[first_child_order_id]
                del self._oco_orders[other_oco_order_id]
        else:
            self._check_oco_order(order.id)
        self._clean_up_child_orders(order.id)

    cdef void _process_order(self, Order order) except *:
        """
        Work the given order.
        """
        Condition.not_in(order.id, self._working_orders, 'order.id', 'working_orders')

        cdef Instrument instrument = self.instruments[order.symbol]

        # Check order size is valid or reject
        if order.quantity > instrument.max_trade_size:
            self._reject_order(order, f'order quantity of {order.quantity} exceeds '
                                      f'the maximum trade size of {instrument.max_trade_size}')
            return  # Cannot accept order
        if order.quantity < instrument.min_trade_size:
            self._reject_order(order, f'order quantity of {order.quantity} is less than '
                                      f'the minimum trade size of {instrument.min_trade_size}')
            return  # Cannot accept order

        cdef Tick current_market = self._market.get(order.symbol)

        # Check market exists
        if current_market is None:  # Market not initialized
            self._reject_order(order, f'no market for {order.symbol}')
            return  # Cannot accept order

        # Check order price is valid or reject
        if not self._check_valid_price(order, current_market, reject=True):
            return  # Cannot accept order

         # Check if market order and accept and fill immediately
        if order.type == OrderType.MARKET:
            self._accept_order(order)

            if order.side == OrderSide.BUY:
                if self.fill_model.is_slipped():
                    self._fill_order(
                        order,
                        current_market.ask.add(
                            self._slippages[order.symbol]))
                else:
                    self._fill_order(order, current_market.ask)
                return  # Market order filled - nothing further to process
            elif order.side == OrderSide.SELL:
                if order.type == OrderType.MARKET:
                    if self.fill_model.is_slipped():
                        self._fill_order(
                            order,
                            current_market.bid.subtract(self._slippages[order.symbol]))
                    else:
                        self._fill_order(order, current_market.bid)
                    return  # Market order filled - nothing further to process

        # Order is valid and accepted
        self._accept_order(order)

        # Order now becomes working
        self._working_orders[order.id] = order

        # Generate event
        cdef OrderWorking working = OrderWorking(
            self._account.id,
            order.id,
            OrderIdBroker('B' + order.id.value),
            order.symbol,
            order.label,
            order.side,
            order.type,
            order.quantity,
            order.price,
            order.time_in_force,
            self._clock.time_now(),
            self._guid_factory.generate(),
            self._clock.time_now(),
            order.expire_time)

        self._exec_engine.handle_event(working)

    cdef void _fill_order(self, Order order, Price fill_price) except *:
        # Generate event
        cdef OrderFilled filled = OrderFilled(
            self._account.id,
            order.id,
            ExecutionId('E-' + order.id.value),
            PositionIdBroker('ET-' + order.id.value),
            order.symbol,
            order.side,
            order.quantity,
            fill_price,
            self.instruments[order.symbol].quote_currency,
            self._clock.time_now(),
            self._guid_factory.generate(),
            self._clock.time_now())

        # Adjust account if position exists and opposite order side
        cdef Position position = self._exec_engine.database.get_position_for_order(order.id)
        if position is not None and position.entry_direction != order.side:
            self.adjust_account(filled, position)

        self._exec_engine.handle_event(filled)
        self._check_oco_order(order.id)

        # Work any atomic child orders
        if order.id in self._atomic_child_orders:
            for child_order in self._atomic_child_orders[order.id]:
                if not child_order.is_completed:  # The order may already be cancelled or rejected
                    self._process_order(child_order)
            del self._atomic_child_orders[order.id]

    cdef void _clean_up_child_orders(self, OrderId order_id) except *:
        # Clean up any residual child orders from the completed order associated
        # with the given identifier.
        if order_id in self._atomic_child_orders:
            del self._atomic_child_orders[order_id]

    cdef void _check_oco_order(self, OrderId order_id) except *:
        # Check held OCO orders and remove any paired with the given order_id
        cdef OrderId oco_order_id
        cdef Order oco_order

        if order_id in self._oco_orders:
            oco_order_id = self._oco_orders[order_id]
            oco_order = self._exec_engine.database.get_order(oco_order_id)
            del self._oco_orders[order_id]
            del self._oco_orders[oco_order_id]

            # Reject any latent atomic child orders
            for atomic_order_id, child_orders in self._atomic_child_orders.items():
                for order in child_orders:
                    if oco_order.equals(order):
                        self._reject_oco_order(order, order_id)

            # Cancel any working OCO orders
            if oco_order_id in self._working_orders:
                self._cancel_oco_order(self._working_orders[oco_order_id], order_id)
                del self._working_orders[oco_order_id]

    cdef void _reject_oco_order(self, Order order, OrderId oco_order_id) except *:
        # order is the OCO order to reject
        # oco_order_id is the other order_id for this OCO pair

        # Generate event
        cdef OrderRejected event = OrderRejected(
            self._account.id,
            order.id,
            self._clock.time_now(),
            ValidString(f"OCO order rejected from {oco_order_id}"),
            self._guid_factory.generate(),
            self._clock.time_now())

        self._exec_engine.handle_event(event)

    cdef void _cancel_oco_order(self, Order order, OrderId oco_order_id) except *:
        # order is the OCO order to cancel
        # oco_order_id is the other order_id for this OCO pair

        # Generate event
        cdef OrderCancelled event = OrderCancelled(
            self._account.id,
            order.id,
            self._clock.time_now(),
            self._guid_factory.generate(),
            self._clock.time_now())

        self._log.debug(f"OCO order cancelled from {oco_order_id}.")
        self._exec_engine.handle_event(event)
