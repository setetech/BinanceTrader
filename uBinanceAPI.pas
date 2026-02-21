unit uBinanceAPI;

interface

uses
  System.SysUtils, System.Classes, System.JSON, System.DateUtils, System.Math,
  System.NetEncoding, System.Hash, System.Net.HttpClient,
  System.Net.URLClient, System.Generics.Collections, System.Generics.Defaults,
  uTypes;

type
  TBinanceAPI = class
  private
    FApiKey, FSecretKey, FBaseURL: string;
    FTestnet: Boolean;
    FTimeOffset: Int64;
    FHttp: THTTPClient;
    FOnLog: TProc<string>;
    function GetTimestamp: Int64;
    function GetLocalTimestamp: Int64;
    function SignQuery(const Q: string): string;
    function DoPublicRequest(const Method, Endpoint: string; const Params: string = ''): TJSONValue;
    procedure Log(const Msg: string);
    function ParseCandle(A: TJSONArray): TCandle;
    procedure SetApiKey(const Value: string);
    procedure SetSecretKey(const Value: string);
  public
    function DoRequest(const Method, Endpoint: string; const Params: string = ''; Signed: Boolean = False): TJSONValue;
    constructor Create(const AApiKey, ASecretKey: string; ATestnet: Boolean = True);
    destructor Destroy; override;
    // Sincroniza relogio com servidor Binance
    procedure SyncServerTime;
    // Market (sempre usa API real para dados de mercado)
    function GetPrice(const Symbol: string): Double;
    function GetKlines(const Symbol, Interval: string; Limit: Integer = 100): TCandleArray;
    function Get24hTicker(const Symbol: string): TJSONObject;
    function GetAll24hTickers: TJSONArray;
    function GetAllTickersWindow(const WindowSize: string = '1d'): TJSONArray;
    function GetOrderBook(const Symbol: string; Limit: Integer = 100): TOrderBookData;
    function GetAISelectSymbols: TArray<string>;
    // Account
    function GetBalance(const Asset: string): TAssetBalance;
    function GetAllBalances(MinTotal: Double = 0): TAssetBalanceArray;
    // Trading
    function GetSymbolFilters(const Symbol: string; out MinQty, StepSize, MinNotional: Double): Boolean;
    function AdjustQuantity(Qty, StepSize, MinQty: Double): Double;
    function PlaceOrder(const Symbol: string; Side: TOrderSide; OType: TOrderType;
      Quantity: Double; Price: Double = 0): TOrderResult;
    // Trade History
    function GetMyTrades(const Symbol: string; Limit: Integer = 50): TJSONArray;
    // Util
    function TestConnectivity: Boolean;
    property ApiKey: string read FApiKey write SetApiKey;
    property SecretKey: string read FSecretKey write SetSecretKey;
    property UseTestnet: Boolean read FTestnet write FTestnet;
    property OnLog: TProc<string> read FOnLog write FOnLog;
    procedure UpdateBaseURL;
  end;

var
  /// FormatSettings com separador decimal ponto (para parsing de APIs)
  FmtDot: TFormatSettings;

implementation

constructor TBinanceAPI.Create(const AApiKey, ASecretKey: string; ATestnet: Boolean);
begin
  inherited Create;
  FApiKey := Trim(AApiKey);
  FSecretKey := Trim(ASecretKey);
  FTestnet := ATestnet;
  FTimeOffset := 0;
  UpdateBaseURL;
  FHttp := THTTPClient.Create;
  FHttp.ConnectionTimeout := 10000;
  FHttp.ResponseTimeout := 30000;
end;

destructor TBinanceAPI.Destroy;
begin
  FHttp.Free;
  inherited;
end;

procedure TBinanceAPI.UpdateBaseURL;
begin
  if FTestnet then FBaseURL := 'https://testnet.binance.vision/api'
  else FBaseURL := 'https://api.binance.com/api';
end;

procedure TBinanceAPI.Log(const Msg: string);
begin
  if Assigned(FOnLog) then
    FOnLog(Msg);
end;

function TBinanceAPI.GetLocalTimestamp: Int64;
begin
  Result := DateTimeToUnix(TTimeZone.Local.ToUniversalTime(Now), False) * 1000;
end;

function TBinanceAPI.GetTimestamp: Int64;
begin
  Result := GetLocalTimestamp + FTimeOffset;
end;

procedure TBinanceAPI.SyncServerTime;
var
  J: TJSONValue;
  ServerTime, LocalTime: Int64;
begin
  LocalTime := GetLocalTimestamp;
  J := DoRequest('GET', '/v3/time');
  try
    if (J <> nil) and (J is TJSONObject) then
    begin
      ServerTime := TJSONObject(J).GetValue<Int64>('serverTime', 0);
      if ServerTime > 0 then
      begin
        FTimeOffset := ServerTime - LocalTime;
        Log(Format('Sync tempo: offset=%dms', [FTimeOffset]));
      end;
    end;
  finally
    J.Free;
  end;
end;

procedure TBinanceAPI.SetApiKey(const Value: string);
begin
  FApiKey := Trim(Value);
end;

procedure TBinanceAPI.SetSecretKey(const Value: string);
begin
  FSecretKey := Trim(Value);
end;

function TBinanceAPI.SignQuery(const Q: string): string;
begin
  Result := THash.DigestAsString(
    THashSHA2.GetHMACAsBytes(
      TEncoding.UTF8.GetBytes(Q),
      TEncoding.UTF8.GetBytes(FSecretKey), SHA256)
  ).ToLower;
end;

function TBinanceAPI.DoRequest(const Method, Endpoint, Params: string; Signed: Boolean): TJSONValue;
var
  URL, Query: string;
  Resp: IHTTPResponse;
begin
  Result := nil;
  URL := FBaseURL + Endpoint;
  Query := Params;
  if Signed then
  begin
    if Query <> '' then Query := Query + '&';
    Query := Query + 'timestamp=' + IntToStr(GetTimestamp);
    Query := Query + '&signature=' + SignQuery(Query);
  end;
  if Signed then
    Log(Format('Request: %s %s | Key: %s...%s (%d chars) | URL: %s',
      [Method, Endpoint,
       Copy(FApiKey, 1, 4), Copy(FApiKey, Length(FApiKey)-3, 4), Length(FApiKey),
       FBaseURL + Endpoint]));

  try
    FHttp.CustomHeaders['X-MBX-APIKEY'] := FApiKey;
    if Method = 'GET' then
    begin
      if Query <> '' then URL := URL + '?' + Query;
      Resp := FHttp.Get(URL);
    end
    else if Method = 'POST' then
    begin
      var S := TStringStream.Create(Query, TEncoding.UTF8);
      try
        FHttp.ContentType := 'application/x-www-form-urlencoded';
        Resp := FHttp.Post(URL, S);
      finally
        S.Free;
      end;
    end
    else if Method = 'DELETE' then
    begin
      if Query <> '' then URL := URL + '?' + Query;
      Resp := FHttp.Delete(URL);
    end;

    if Resp.StatusCode = 200 then
    begin
      Result := TJSONObject.ParseJSONValue(Resp.ContentAsString(TEncoding.UTF8));
      if (not Signed) and (Pos('/ticker/price', Endpoint) = 0) then
      begin
        if Params <> '' then
          Log('OK: ' + Method + ' ' + Endpoint + '?' + Params)
        else
          Log('OK: ' + Method + ' ' + Endpoint);
      end;
    end else
    begin
      Log('ERRO ' + IntToStr(Resp.StatusCode) + ': ' + Resp.ContentAsString(TEncoding.UTF8));
      Result := TJSONObject.ParseJSONValue(Resp.ContentAsString(TEncoding.UTF8));
    end;
  except
    on E: Exception do Log('Excecao: ' + E.Message);
  end;
end;

// Requisicao publica SEMPRE na API real (para dados de mercado)
function TBinanceAPI.DoPublicRequest(const Method, Endpoint: string; const Params: string): TJSONValue;
var
  URL: string;
  Resp: IHTTPResponse;
begin
  Result := nil;
  URL := 'https://api.binance.com/api' + Endpoint;
  try
    if Params <> '' then URL := URL + '?' + Params;
    Resp := FHttp.Get(URL);
    if Resp.StatusCode = 200 then
    begin
      Result := TJSONObject.ParseJSONValue(Resp.ContentAsString(TEncoding.UTF8));
      // Nao loga ticker/price (chamado a cada 5s pelo timer, polui o log)
      if Pos('/ticker/price', Endpoint) = 0 then
      begin
        if Params <> '' then
          Log('OK: ' + Method + ' ' + Endpoint + '?' + Params)
        else
          Log('OK: ' + Method + ' ' + Endpoint);
      end;
    end else
    begin
      Log('ERRO ' + IntToStr(Resp.StatusCode) + ': ' + Resp.ContentAsString(TEncoding.UTF8));
      Result := TJSONObject.ParseJSONValue(Resp.ContentAsString(TEncoding.UTF8));
    end;
  except
    on E: Exception do Log('Excecao: ' + E.Message);
  end;
end;

function TBinanceAPI.ParseCandle(A: TJSONArray): TCandle;
begin
  Result.Clear;
  if A.Count >= 12 then
  begin
    Result.OpenTime := UnixToDateTime(A.Items[0].AsType<Int64> div 1000, False);
    Result.Open := StrToFloatDef(A.Items[1].Value, 0, FmtDot);
    Result.High := StrToFloatDef(A.Items[2].Value, 0, FmtDot);
    Result.Low := StrToFloatDef(A.Items[3].Value, 0, FmtDot);
    Result.Close := StrToFloatDef(A.Items[4].Value, 0, FmtDot);
    Result.Volume := StrToFloatDef(A.Items[5].Value, 0, FmtDot);
    Result.CloseTime := UnixToDateTime(A.Items[6].AsType<Int64> div 1000, False);
    Result.QuoteVolume := StrToFloatDef(A.Items[7].Value, 0, FmtDot);
    Result.Trades := A.Items[8].AsType<Integer>;
  end;
end;

function TBinanceAPI.GetPrice(const Symbol: string): Double;
var J: TJSONValue;
begin
  Result := 0;
  J := DoPublicRequest('GET', '/v3/ticker/price', 'symbol=' + Symbol);
  try
    if (J <> nil) and (J is TJSONObject) then
      Result := StrToFloatDef(TJSONObject(J).GetValue<string>('price', '0'), 0, FmtDot);
  finally
    J.Free;
  end;
end;

function TBinanceAPI.GetKlines(const Symbol, Interval: string; Limit: Integer): TCandleArray;
var J: TJSONValue; A: TJSONArray; I: Integer;
begin
  SetLength(Result, 0);
  J := DoPublicRequest('GET', '/v3/klines', Format('symbol=%s&interval=%s&limit=%d', [Symbol, Interval, Limit]));
  try
    if (J <> nil) and (J is TJSONArray) then
    begin
      A := TJSONArray(J);
      SetLength(Result, A.Count);
      for I := 0 to A.Count - 1 do
        Result[I] := ParseCandle(TJSONArray(A.Items[I]));
    end;
  finally
    J.Free;
  end;
end;

function TBinanceAPI.Get24hTicker(const Symbol: string): TJSONObject;
var J: TJSONValue;
begin
  Result := nil;
  J := DoPublicRequest('GET', '/v3/ticker/24hr', 'symbol=' + Symbol);
  if (J <> nil) and (J is TJSONObject) then Result := TJSONObject(J)
  else J.Free;
end;

function TBinanceAPI.GetAll24hTickers: TJSONArray;
var J: TJSONValue;
begin
  Result := nil;
  J := DoPublicRequest('GET', '/v3/ticker/24hr');
  if (J <> nil) and (J is TJSONArray) then
    Result := TJSONArray(J)
  else
    J.Free;
end;

function TBinanceAPI.GetAllTickersWindow(const WindowSize: string): TJSONArray;
var
  LAll24h, LBatch: TJSONArray;
  LSymbols: TStringList;
  I, LStart, LBatchSize: Integer;
  LObj: TJSONObject;
  LSym, LSymParam: string;
  J: TJSONValue;
begin
  // Para 1d (24h) usa o endpoint nativo que retorna todos os tickers
  if (WindowSize = '') or (WindowSize = '1d') then
  begin
    Result := GetAll24hTickers;
    Exit;
  end;

  // Para outros periodos: /v3/ticker exige 'symbol' ou 'symbols'.
  // Passo 1: busca todos via /v3/ticker/24hr para descobrir os pares USDT
  LAll24h := GetAll24hTickers;
  if LAll24h = nil then begin Result := nil; Exit; end;

  LSymbols := TStringList.Create;
  Result := TJSONArray.Create;
  try
    for I := 0 to LAll24h.Count - 1 do
    begin
      LObj := TJSONObject(LAll24h.Items[I]);
      LSym := LObj.GetValue<string>('symbol', '');
      if LSym.EndsWith('USDT') and
         (StrToFloatDef(LObj.GetValue<string>('quoteVolume', '0'), 0, FmtDot) >= 500000) then
        LSymbols.Add(LSym);
    end;
  finally
    LAll24h.Free;
  end;

  if LSymbols.Count = 0 then
  begin
    LSymbols.Free;
    Exit;
  end;

  // Passo 2: consulta /v3/ticker em lotes com windowSize customizado
  try
    LBatchSize := 100;
    LStart := 0;
    while LStart < LSymbols.Count do
    begin
      // Monta JSON array de simbolos: ["BTCUSDT","ETHUSDT",...]
      LSymParam := '[';
      for I := LStart to Min(LStart + LBatchSize - 1, LSymbols.Count - 1) do
      begin
        if I > LStart then LSymParam := LSymParam + ',';
        LSymParam := LSymParam + '"' + LSymbols[I] + '"';
      end;
      LSymParam := LSymParam + ']';

      J := DoPublicRequest('GET', '/v3/ticker',
        'symbols=' + TNetEncoding.URL.Encode(LSymParam) + '&windowSize=' + WindowSize);
      if (J <> nil) and (J is TJSONArray) then
      begin
        LBatch := TJSONArray(J);
        for I := 0 to LBatch.Count - 1 do
          Result.AddElement(LBatch.Items[I].Clone as TJSONValue);
        LBatch.Free;
      end
      else
        J.Free;

      Inc(LStart, LBatchSize);
    end;
  finally
    LSymbols.Free;
  end;
end;

function TBinanceAPI.GetOrderBook(const Symbol: string; Limit: Integer): TOrderBookData;
var
  J: TJSONValue;
  JObj: TJSONObject;
  Bids, Asks: TJSONArray;
  I: Integer;
  P, Q: Double;
begin
  FillChar(Result, SizeOf(Result), 0);
  Result.Symbol := Symbol;
  if Limit > 1000 then Limit := 1000;

  J := DoPublicRequest('GET', '/v3/depth', Format('symbol=%s&limit=%d', [Symbol, Limit]));
  try
    if (J = nil) or not (J is TJSONObject) then Exit;
    JObj := TJSONObject(J);

    Bids := nil; Asks := nil;
    if JObj.FindValue('bids') is TJSONArray then Bids := TJSONArray(JObj.FindValue('bids'));
    if JObj.FindValue('asks') is TJSONArray then Asks := TJSONArray(JObj.FindValue('asks'));

    // Parse bids
    if (Bids <> nil) and (Bids.Count > 0) then
    begin
      SetLength(Result.Bids, Bids.Count);
      for I := 0 to Bids.Count - 1 do
      begin
        P := StrToFloatDef(TJSONArray(Bids.Items[I]).Items[0].Value, 0, FmtDot);
        Q := StrToFloatDef(TJSONArray(Bids.Items[I]).Items[1].Value, 0, FmtDot);
        Result.Bids[I].Price := P;
        Result.Bids[I].Quantity := Q;
        Result.BidTotal := Result.BidTotal + (P * Q);
        if (P * Q) > Result.BiggestBidWall then
        begin
          Result.BiggestBidWall := P * Q;
          Result.BiggestBidWallPrice := P;
        end;
      end;
      Result.BestBid := Result.Bids[0].Price;
    end;

    // Parse asks
    if (Asks <> nil) and (Asks.Count > 0) then
    begin
      SetLength(Result.Asks, Asks.Count);
      for I := 0 to Asks.Count - 1 do
      begin
        P := StrToFloatDef(TJSONArray(Asks.Items[I]).Items[0].Value, 0, FmtDot);
        Q := StrToFloatDef(TJSONArray(Asks.Items[I]).Items[1].Value, 0, FmtDot);
        Result.Asks[I].Price := P;
        Result.Asks[I].Quantity := Q;
        Result.AskTotal := Result.AskTotal + (P * Q);
        if (P * Q) > Result.BiggestAskWall then
        begin
          Result.BiggestAskWall := P * Q;
          Result.BiggestAskWallPrice := P;
        end;
      end;
      Result.BestAsk := Result.Asks[0].Price;
    end;

    // Calcula imbalance: bid/(bid+ask) - 0.5=neutro
    if (Result.BidTotal + Result.AskTotal) > 0 then
      Result.Imbalance := Result.BidTotal / (Result.BidTotal + Result.AskTotal)
    else
      Result.Imbalance := 0.5;

    // Calcula spread %
    if Result.BestBid > 0 then
      Result.Spread := ((Result.BestAsk - Result.BestBid) / Result.BestBid) * 100;
  finally
    J.Free;
  end;
end;

function TBinanceAPI.GetBalance(const Asset: string): TAssetBalance;
var Acc: TJSONValue; BalsVal: TJSONValue; Bals: TJSONArray; I: Integer; B: TJSONObject;
begin
  Result.Asset := Asset; Result.Free := 0; Result.Locked := 0;
  Acc := DoRequest('GET', '/v3/account', '', True);
  try
    if (Acc <> nil) and (Acc is TJSONObject) then
    begin
      BalsVal := TJSONObject(Acc).FindValue('balances');
      if (BalsVal <> nil) and (BalsVal is TJSONArray) then
      begin
        Bals := TJSONArray(BalsVal);
        for I := 0 to Bals.Count - 1 do
        begin
          B := TJSONObject(Bals.Items[I]);
          if B.GetValue<string>('asset', '') = Asset then
          begin
            Result.Free := StrToFloatDef(B.GetValue<string>('free', '0'), 0, FmtDot);
            Result.Locked := StrToFloatDef(B.GetValue<string>('locked', '0'), 0, FmtDot);
            Break;
          end;
        end;
      end;
    end;
  finally
    Acc.Free;
  end;
end;

function TBinanceAPI.GetAllBalances(MinTotal: Double): TAssetBalanceArray;
var Acc: TJSONValue; BalsVal: TJSONValue; Bals: TJSONArray; I, Count: Integer; B: TJSONObject;
    Bal: TAssetBalance; Total: Double;
begin
  SetLength(Result, 0);
  Acc := DoRequest('GET', '/v3/account', '', True);
  try
    if (Acc <> nil) and (Acc is TJSONObject) then
    begin
      BalsVal := TJSONObject(Acc).FindValue('balances');
      if (BalsVal <> nil) and (BalsVal is TJSONArray) then
      begin
        Bals := TJSONArray(BalsVal);
        Count := 0;
        SetLength(Result, Bals.Count);
        for I := 0 to Bals.Count - 1 do
        begin
          B := TJSONObject(Bals.Items[I]);
          Bal.Asset := B.GetValue<string>('asset', '');
          Bal.Free := StrToFloatDef(B.GetValue<string>('free', '0'), 0, FmtDot);
          Bal.Locked := StrToFloatDef(B.GetValue<string>('locked', '0'), 0, FmtDot);
          Total := Bal.Free + Bal.Locked;
          if Total > MinTotal then
          begin
            Result[Count] := Bal;
            Inc(Count);
          end;
        end;
        SetLength(Result, Count);
      end;
    end;
  finally
    Acc.Free;
  end;
end;

function TBinanceAPI.GetAISelectSymbols: TArray<string>;
var
  URL: string;
  Resp: IHTTPResponse;
  J: TJSONValue;
  JObj: TJSONObject;
  Arr: TJSONArray;
  I, LRank: Integer;
  Asset, Sym: string;
  Ranked: TList<TPair<Integer, string>>;
begin
  Result := nil;
  URL := 'https://www.binance.com/bapi/apex/v1/friendly/apex/web/opportunity/assets?interval=24h&type=sentiment';
  try
    Resp := FHttp.Get(URL);
    Log('AI Select: HTTP ' + IntToStr(Resp.StatusCode));
    if Resp.StatusCode = 200 then
    begin
      var LRaw := Resp.ContentAsString(TEncoding.UTF8);
      J := TJSONObject.ParseJSONValue(LRaw);
      if J = nil then
      begin
        Log('AI Select: JSON parse falhou, resp=' + Copy(LRaw, 1, 200));
        Exit;
      end;
      try
        Arr := nil;
        // Estrutura: { "data": { "items": [...] } }
        var LItems := J.FindValue('data.items');
        if (LItems <> nil) and (LItems is TJSONArray) then
          Arr := TJSONArray(LItems)
        else
        begin
          // Fallback: data direto como array
          var LData := J.FindValue('data');
          if (LData <> nil) and (LData is TJSONArray) then
            Arr := TJSONArray(LData);
        end;

        if Arr = nil then
        begin
          Log('AI Select: campo data.items nao encontrado');
          Exit;
        end;

        Log(Format('AI Select: %d itens no JSON', [Arr.Count]));
        Ranked := TList<TPair<Integer, string>>.Create;
        try
          for I := 0 to Arr.Count - 1 do
          begin
            if not (Arr.Items[I] is TJSONObject) then Continue;
            var LItem := TJSONObject(Arr.Items[I]);
            Asset := LItem.GetValue<string>('asset', '');
            LRank := LItem.GetValue<Integer>('rank', 9999);
            // Filtra apenas sentimento positivo: "Strong Positive" ou "Positive"
            var LLabel := '';
            var LSentVal := LItem.FindValue('metrics.sentiment_score.valueLabel');
            if LSentVal <> nil then
              LLabel := LSentVal.Value;
            if (Asset <> '') and (Pos('Positive', LLabel) > 0) then
            begin
              Sym := Asset + 'USDT';
              Ranked.Add(TPair<Integer, string>.Create(LRank, Sym));
            end;
          end;
          // Ordena por rank
          Ranked.Sort(TComparer<TPair<Integer, string>>.Construct(
            function(const A, B: TPair<Integer, string>): Integer
            begin
              Result := A.Key - B.Key;
            end));
          SetLength(Result, Ranked.Count);
          for I := 0 to Ranked.Count - 1 do
            Result[I] := Ranked[I].Value;
          Log(Format('AI Select: %d moedas da Binance (sentiment)', [Length(Result)]));
        finally
          Ranked.Free;
        end;
      finally
        J.Free;
      end;
    end;
  except
    on E: Exception do
      Log('AI Select: ' + E.Message);
  end;
end;

function TBinanceAPI.GetSymbolFilters(const Symbol: string; out MinQty, StepSize, MinNotional: Double): Boolean;
var
  J: TJSONValue;
  Symbols, Filters: TJSONArray;
  K: Integer;
  Sym, Flt: TJSONObject;
  FType: string;
  FoundLot: Boolean;
begin
  Result := False;
  MinQty := 0.001;
  StepSize := 0.001;
  MinNotional := 5.0;
  FoundLot := False;
  J := DoPublicRequest('GET', '/v3/exchangeInfo', 'symbol=' + Symbol);
  try
    if (J <> nil) and (J is TJSONObject) then
    begin
      Symbols := TJSONObject(J).GetValue<TJSONArray>('symbols');
      if (Symbols <> nil) and (Symbols.Count > 0) then
      begin
        Sym := TJSONObject(Symbols.Items[0]);
        Filters := Sym.GetValue<TJSONArray>('filters');
        if Filters <> nil then
          for K := 0 to Filters.Count - 1 do
          begin
            Flt := TJSONObject(Filters.Items[K]);
            FType := Flt.GetValue<string>('filterType', '');
            if FType = 'LOT_SIZE' then
            begin
              MinQty := StrToFloatDef(Flt.GetValue<string>('minQty', '0.001'), 0.001, FmtDot);
              StepSize := StrToFloatDef(Flt.GetValue<string>('stepSize', '0.001'), 0.001, FmtDot);
              FoundLot := True;
            end
            else if (FType = 'NOTIONAL') or (FType = 'MIN_NOTIONAL') then
            begin
              MinNotional := StrToFloatDef(Flt.GetValue<string>('minNotional', '5'), 5, FmtDot);
            end;
          end;
        Result := FoundLot;
        Log(Format('Filtros %s: lotMin=%s step=%s notional=%s',
          [Symbol, FormatFloat('0.########', MinQty, FmtDot),
           FormatFloat('0.########', StepSize, FmtDot),
           FormatFloat('0.##', MinNotional, FmtDot)]));
      end;
    end;
  finally
    J.Free;
  end;
end;

function TBinanceAPI.AdjustQuantity(Qty, StepSize, MinQty: Double): Double;
begin
  if StepSize > 0 then
    Result := Floor(Qty / StepSize) * StepSize
  else
    Result := Qty;
  if Result < MinQty then
    Result := 0;
end;

function TBinanceAPI.PlaceOrder(const Symbol: string; Side: TOrderSide;
  OType: TOrderType; Quantity, Price: Double): TOrderResult;
var P: string; J: TJSONValue; O: TJSONObject;
    LMinQty, LStepSize, LMinNotional, LAdjQty, LCurrentPrice, LNotional: Double;
begin
  Result.Success := False; Result.Symbol := Symbol; Result.Side := Side;
  Result.Quantity := Quantity; Result.Timestamp := Now;

  // Obtem preco atual para validar notional
  LCurrentPrice := GetPrice(Symbol);
  if LCurrentPrice <= 0 then
  begin
    Result.ErrorMsg := 'Nao foi possivel obter preco atual de ' + Symbol;
    Log('Erro: ' + Result.ErrorMsg);
    Exit;
  end;

  // Obtem filtros do par (LOT_SIZE + NOTIONAL)
  if GetSymbolFilters(Symbol, LMinQty, LStepSize, LMinNotional) then
  begin
    // Ajusta quantidade pelo step size
    LAdjQty := AdjustQuantity(Quantity, LStepSize, LMinQty);
    if LAdjQty <= 0 then
    begin
      Result.ErrorMsg := Format('Quantidade %s abaixo do minimo %s',
        [FormatFloat('0.########', Quantity, FmtDot),
         FormatFloat('0.########', LMinQty, FmtDot)]);
      Log('Erro: ' + Result.ErrorMsg);
      Exit;
    end;

    // Verifica notional minimo (qty * price >= minNotional)
    LNotional := LAdjQty * LCurrentPrice;
    if LNotional < LMinNotional then
    begin
      if Side = osSell then
      begin
        // SELL: nao pode aumentar qty alem do que temos
        Result.ErrorMsg := Format('Valor da posicao ($%.2f) abaixo do minimo notional ($%.2f). ' +
          'Use "Converter pequenos saldos" na Binance.',
          [LNotional, LMinNotional]);
        Log('Erro: ' + Result.ErrorMsg);
        Exit;
      end;
      // BUY: aumenta qty para atingir o notional minimo
      LAdjQty := Ceil(LMinNotional / LCurrentPrice / LStepSize) * LStepSize;
      LNotional := LAdjQty * LCurrentPrice;
      Log(Format('Ajustando qty para notional minimo: %s (valor: $%s)',
        [FormatFloat('0.########', LAdjQty, FmtDot),
         FormatFloat('0.##', LNotional, FmtDot)]));
    end;

    Quantity := LAdjQty;
    Result.Quantity := Quantity;
  end;

  P := Format('symbol=%s&side=%s&type=%s&quantity=%s',
    [Symbol, OrderSideToStr(Side), OrderTypeToStr(OType),
     FormatFloat('0.########', Quantity, FmtDot)]);
  if OType in [otLimit, otStopLossLimit, otTakeProfitLimit] then
    P := P + '&price=' + FormatFloat('0.########', Price, FmtDot) + '&timeInForce=GTC';

  Log('Ordem: ' + P);
  J := DoRequest('POST', '/v3/order', P, True);
  try
    if (J <> nil) and (J is TJSONObject) then
    begin
      O := TJSONObject(J);
      if O.FindValue('orderId') <> nil then
      begin
        Result.OrderId := O.GetValue<Int64>('orderId');
        Result.Status := O.GetValue<string>('status', '');
        Result.Price := StrToFloatDef(O.GetValue<string>('price', '0'), 0, FmtDot);
        // Para ordens MARKET, price=0 - extrair preco real dos fills
        if (Result.Price <= 0) then
        begin
          var Fills := O.GetValue<TJSONArray>('fills');
          if (Fills <> nil) and (Fills.Count > 0) then
          begin
            var TotalQty: Double := 0;
            var TotalCost: Double := 0;
            for var FI := 0 to Fills.Count - 1 do
            begin
              var Fill := TJSONObject(Fills.Items[FI]);
              var FP := StrToFloatDef(Fill.GetValue<string>('price', '0'), 0, FmtDot);
              var FQ := StrToFloatDef(Fill.GetValue<string>('qty', '0'), 0, FmtDot);
              TotalCost := TotalCost + (FP * FQ);
              TotalQty := TotalQty + FQ;
            end;
            if TotalQty > 0 then
              Result.Price := TotalCost / TotalQty;
          end;
        end;
        // Fallback: usar preco passado como parametro
        if Result.Price <= 0 then
          Result.Price := Price;
        Result.Quantity := StrToFloatDef(O.GetValue<string>('executedQty', '0'), Quantity, FmtDot);
        Result.Success := True;
        Log(Format('Ordem OK! ID=%d Preco=%.8f Qty=%.8f',
          [Result.OrderId, Result.Price, Result.Quantity], FmtDot));
      end else
      begin
        Result.ErrorMsg := O.GetValue<string>('msg', 'Erro desconhecido');
        Log('Erro: ' + Result.ErrorMsg);
      end;
    end else
      Result.ErrorMsg := 'Sem resposta';
  finally
    J.Free;
  end;
end;

function TBinanceAPI.GetMyTrades(const Symbol: string; Limit: Integer): TJSONArray;
var J: TJSONValue;
begin
  Result := nil;
  J := DoRequest('GET', '/v3/myTrades',
    Format('symbol=%s&limit=%d', [Symbol, Limit]), True);
  try
    if (J <> nil) and (J is TJSONArray) then
    begin
      Result := TJSONArray(J.Clone);
    end;
  finally
    J.Free;
  end;
  if Result = nil then
    Result := TJSONArray.Create;
end;

function TBinanceAPI.TestConnectivity: Boolean;
var J: TJSONValue;
begin
  J := DoRequest('GET', '/v3/ping');
  try Result := J <> nil; finally J.Free; end;
end;

initialization
  FmtDot := TFormatSettings.Create('en-US');
  FmtDot.DecimalSeparator := '.';
  FmtDot.ThousandSeparator := ',';

end.
