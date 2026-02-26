unit uTypes;

interface

uses
  System.SysUtils, System.Generics.Collections;

type
  TCandle = record
    OpenTime: TDateTime;
    Open, High, Low, Close, Volume: Double;
    CloseTime: TDateTime;
    QuoteVolume: Double;
    Trades: Integer;
    procedure Clear;
  end;
  TCandleArray = TArray<TCandle>;

  TOrderSide  = (osBuy, osSell);
  TOrderType  = (otMarket, otLimit, otStopLoss, otStopLossLimit, otTakeProfit, otTakeProfitLimit);
  TTradeSignal = (tsStrongBuy, tsBuy, tsHold, tsSell, tsStrongSell);

  TAIAnalysis = record
    Signal: TTradeSignal;
    Confidence: Double;
    Reasoning: string;
    SuggestedEntry, SuggestedStopLoss, SuggestedTakeProfit: Double;
    Timestamp: TDateTime;
  end;

  TTechnicalIndicators = record
    RSI, MACD, MACDSignal, MACDHistogram: Double;
    SMA20, SMA50, EMA12, EMA26: Double;
    BollingerUpper, BollingerMiddle, BollingerLower: Double;
    ATR, CurrentPrice, PriceChange24h, Volume24h: Double;
    // Order Book
    OBImbalance: Double;   // 0-1, >0.6=bullish, <0.4=bearish
    OBSpread: Double;      // % spread
    OBBidTotal, OBAskTotal: Double;
    OBBigBidWall, OBBigAskWall: Double;
    OBBigBidPrice, OBBigAskPrice: Double;
    function ToText: string;
  end;

  TOrderResult = record
    OrderId: Int64;
    Symbol: string;
    Side: TOrderSide;
    OrderType: TOrderType;
    Price, Quantity: Double;
    Status, ErrorMsg: string;
    Timestamp: TDateTime;
    Success: Boolean;
  end;

  TAssetBalance = record
    Asset: string;
    Free, Locked: Double;
  end;
  TAssetBalanceArray = TArray<TAssetBalance>;

  TOpenPosition = record
    Symbol: string;
    BuyPrice: Double;
    BuyTime: TDateTime;
    Quantity: Double;
    HighestPrice: Double;
  end;

  TOrderBookLevel = record
    Price: Double;
    Quantity: Double;
  end;

  TOrderBookData = record
    Symbol: string;
    BidTotal, AskTotal: Double;         // Volume total de bids/asks
    Imbalance: Double;                   // bid/(bid+ask) - 0.5=neutro, >0.6=bullish, <0.4=bearish
    Spread: Double;                      // % spread entre best bid e best ask
    BestBid, BestAsk: Double;
    BiggestBidWall, BiggestAskWall: Double;       // Maior ordem
    BiggestBidWallPrice, BiggestAskWallPrice: Double; // Preco da maior ordem
    Bids, Asks: TArray<TOrderBookLevel>;
  end;

  TCoinRecovery = record
    Symbol: string;
    Price: Double;
    PriceChangePercent: Double;
    Volume: Double;
    HighPrice: Double;
    LowPrice: Double;
    QuoteVolume: Double;
    PrevClosePrice: Double;  // Preco de fechamento 24h atras (evita re-fetch)
    ScanMetric: Double;  // Valor especifico do filtro (RSI, squeeze, etc.)
  end;
  TCoinRecoveryArray = TArray<TCoinRecovery>;

  function SignalToStr(S: TTradeSignal): string;
  function SignalToStrEN(S: TTradeSignal): string;
  function StrENToSignal(const S: string): TTradeSignal;
  function OrderSideToStr(S: TOrderSide): string;
  function OrderTypeToStr(T: TOrderType): string;

implementation

procedure TCandle.Clear;
begin
  FillChar(Self, SizeOf(Self), 0);
end;

function TTechnicalIndicators.ToText: string;
var
  Fmt: TFormatSettings;
begin
  Fmt := TFormatSettings.Create;
  Fmt.DecimalSeparator := '.';
  Result := Format(
    'Preco Atual: %.8f'#13#10 +
    'Variacao 24h: %.2f%%'#13#10 +
    'Volume 24h: %.2f'#13#10 +
    'RSI(14): %.2f'#13#10 +
    'MACD: %.8f | Signal: %.8f | Hist: %.8f'#13#10 +
    'SMA20: %.8f | SMA50: %.8f'#13#10 +
    'EMA12: %.8f | EMA26: %.8f'#13#10 +
    'Bollinger: %.8f / %.8f / %.8f'#13#10 +
    'ATR(14): %.8f',
    [CurrentPrice, PriceChange24h, Volume24h,
     RSI, MACD, MACDSignal, MACDHistogram,
     SMA20, SMA50, EMA12, EMA26,
     BollingerUpper, BollingerMiddle, BollingerLower, ATR], Fmt);
  // Order Book (so inclui se foi preenchido)
  if OBImbalance > 0 then
  begin
    Result := Result + Format(#13#10 +
      'OrderBook Imbalance: %.2f (>0.6=bullish, <0.4=bearish)'#13#10 +
      'OrderBook Spread: %.4f%%'#13#10 +
      'Bids Total: $%.0f | Asks Total: $%.0f'#13#10 +
      'Maior Buy Wall: $%.0f @ %.8f'#13#10 +
      'Maior Sell Wall: $%.0f @ %.8f',
      [OBImbalance, OBSpread,
       OBBidTotal, OBAskTotal,
       OBBigBidWall, OBBigBidPrice,
       OBBigAskWall, OBBigAskPrice], Fmt);
  end;
end;

function SignalToStr(S: TTradeSignal): string;
begin
  case S of
    tsStrongBuy:  Result := 'COMPRA FORTE';
    tsBuy:        Result := 'COMPRA';
    tsHold:       Result := 'MANTER';
    tsSell:       Result := 'VENDA';
    tsStrongSell: Result := 'VENDA FORTE';
  end;
end;

function SignalToStrEN(S: TTradeSignal): string;
begin
  case S of
    tsStrongBuy:  Result := 'STRONG_BUY';
    tsBuy:        Result := 'BUY';
    tsHold:       Result := 'HOLD';
    tsSell:       Result := 'SELL';
    tsStrongSell: Result := 'STRONG_SELL';
  end;
end;

function StrENToSignal(const S: string): TTradeSignal;
begin
  if S = 'STRONG_BUY' then Result := tsStrongBuy
  else if S = 'BUY' then Result := tsBuy
  else if S = 'SELL' then Result := tsSell
  else if S = 'STRONG_SELL' then Result := tsStrongSell
  else Result := tsHold;
end;

function OrderSideToStr(S: TOrderSide): string;
begin
  case S of osBuy: Result := 'BUY'; osSell: Result := 'SELL'; end;
end;

function OrderTypeToStr(T: TOrderType): string;
begin
  case T of
    otMarket:          Result := 'MARKET';
    otLimit:           Result := 'LIMIT';
    otStopLoss:        Result := 'STOP_LOSS';
    otStopLossLimit:   Result := 'STOP_LOSS_LIMIT';
    otTakeProfit:      Result := 'TAKE_PROFIT';
    otTakeProfitLimit: Result := 'TAKE_PROFIT_LIMIT';
  end;
end;

end.
