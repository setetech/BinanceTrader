unit uDatabase;

interface

uses
  System.SysUtils, System.Classes, System.DateUtils, System.JSON,
  System.Generics.Collections,
  Uni, UniProvider, SQLiteUniProvider,
  uTypes;

type
  TDatabase = class
  private
    FConn: TUniConnection;
    procedure CreateTables;
  public
    constructor Create(const ADbPath: string);
    destructor Destroy; override;
    // Trades
    procedure SaveTrade(const Symbol, Side: string; Price, Quantity: Double;
      const Signal: string; Confidence: Double; OrderId: Int64; Timestamp: TDateTime);
    function LoadTrades: TJSONArray;
    function GetTradedSymbols: TArray<string>;
    // Posicoes abertas
    procedure SavePosition(const Symbol: string; BuyPrice: Double;
      BuyTime: TDateTime; Quantity: Double; HighestPrice: Double = 0);
    procedure DeletePosition(const Symbol: string);
    procedure DeleteAllPositions(const Symbol: string);
    function LoadPositions: TList<TOpenPosition>;
    procedure UpdatePositionHighPrice(const Symbol: string; HighPrice: Double);
    // Wallet snapshots
    procedure SaveWalletSnapshot(TotalUSDT: Double; Timestamp: TDateTime);
    function LoadWalletSnapshots(MaxRecords: Integer = 500): TJSONArray;
    // AI cache
    procedure SaveAIAnalysis(const Symbol: string; const Analysis: TAIAnalysis);
    function LoadAICache: TDictionary<string, TAIAnalysis>;
  end;

implementation

uses
  Data.DB;

constructor TDatabase.Create(const ADbPath: string);
begin
  inherited Create;
  FConn := TUniConnection.Create(nil);
  FConn.ProviderName := 'SQLite';
  FConn.Database := ADbPath;
  FConn.SpecificOptions.Values['sqlite.Direct']:='True';
  FConn.SpecificOptions.Values['sqlite.ForceCreateDatabase']:='True';
  FConn.SpecificOptions.Values['sqlite.UseUnicode']:='True';
  FConn.LoginPrompt := False;
  FConn.Connect;
  // Garante encoding UTF-8 para caracteres Unicode (ex: moedas asiaticas)
  FConn.ExecSQL('PRAGMA encoding = "UTF-8"');
  CreateTables;
end;

destructor TDatabase.Destroy;
begin
  if FConn.Connected then
    FConn.Disconnect;
  FConn.Free;
  inherited;
end;

procedure TDatabase.CreateTables;
var
  Q: TUniQuery;
begin
  Q := TUniQuery.Create(nil);
  try
    Q.Connection := FConn;

    Q.SQL.Text :=
      'CREATE TABLE IF NOT EXISTS trades (' +
      '  id INTEGER PRIMARY KEY AUTOINCREMENT,' +
      '  timestamp TEXT NOT NULL,' +
      '  symbol TEXT NOT NULL,' +
      '  side TEXT NOT NULL,' +
      '  price REAL NOT NULL,' +
      '  quantity REAL NOT NULL,' +
      '  signal TEXT,' +
      '  confidence REAL,' +
      '  order_id INTEGER' +
      ')';
    Q.Execute;

    Q.SQL.Text :=
      'CREATE TABLE IF NOT EXISTS open_positions (' +
      '  id INTEGER PRIMARY KEY AUTOINCREMENT,' +
      '  symbol TEXT NOT NULL,' +
      '  buy_price REAL NOT NULL,' +
      '  buy_time TEXT NOT NULL,' +
      '  quantity REAL NOT NULL,' +
      '  high_price REAL NOT NULL DEFAULT 0' +
      ')';
    Q.Execute;

    // Migra bancos antigos que nao tem a coluna high_price
    try
      Q.SQL.Text := 'ALTER TABLE open_positions ADD COLUMN high_price REAL NOT NULL DEFAULT 0';
      Q.Execute;
    except
      // Coluna ja existe - ignora
    end;

    Q.SQL.Text :=
      'CREATE TABLE IF NOT EXISTS wallet_snapshots (' +
      '  id INTEGER PRIMARY KEY AUTOINCREMENT,' +
      '  timestamp TEXT NOT NULL,' +
      '  total_usdt REAL NOT NULL' +
      ')';
    Q.Execute;

    Q.SQL.Text :=
      'CREATE TABLE IF NOT EXISTS ai_cache (' +
      '  symbol TEXT PRIMARY KEY,' +
      '  signal TEXT NOT NULL,' +
      '  confidence REAL NOT NULL,' +
      '  reasoning TEXT,' +
      '  entry REAL,' +
      '  stop_loss REAL,' +
      '  take_profit REAL,' +
      '  timestamp TEXT NOT NULL' +
      ')';
    Q.Execute;

    // Remove registros com symbols corrompidos (caracteres ? de encoding errado)
    Q.SQL.Text := 'DELETE FROM ai_cache WHERE symbol LIKE ''%?%''';
    Q.Execute;
  finally
    Q.Free;
  end;
end;

procedure TDatabase.SaveTrade(const Symbol, Side: string; Price, Quantity: Double;
  const Signal: string; Confidence: Double; OrderId: Int64; Timestamp: TDateTime);
var
  Q: TUniQuery;
begin
  Q := TUniQuery.Create(nil);
  try
    Q.Connection := FConn;
    Q.SQL.Text :=
      'INSERT INTO trades (timestamp, symbol, side, price, quantity, signal, confidence, order_id) ' +
      'VALUES (:ts, :sym, :side, :price, :qty, :sig, :conf, :oid)';
    Q.ParamByName('ts').AsString := FormatDateTime('dd/mm/yyyy hh:nn:ss', Timestamp);
    Q.ParamByName('sym').AsString := Symbol;
    Q.ParamByName('side').AsString := Side;
    Q.ParamByName('price').AsFloat := Price;
    Q.ParamByName('qty').AsFloat := Quantity;
    Q.ParamByName('sig').AsString := Signal;
    Q.ParamByName('conf').AsFloat := Confidence;
    Q.ParamByName('oid').AsLargeInt := OrderId;
    Q.Execute;
  finally
    Q.Free;
  end;
end;

function TDatabase.LoadTrades: TJSONArray;
var
  Q: TUniQuery;
  Obj: TJSONObject;
begin
  Result := TJSONArray.Create;
  Q := TUniQuery.Create(nil);
  try
    Q.Connection := FConn;
    Q.SQL.Text := 'SELECT * FROM trades ORDER BY id DESC';
    Q.Open;
    while not Q.Eof do
    begin
      Obj := TJSONObject.Create;
      Obj.AddPair('timestamp', Q.FieldByName('timestamp').AsString);
      Obj.AddPair('symbol', Q.FieldByName('symbol').AsString);
      Obj.AddPair('side', Q.FieldByName('side').AsString);
      Obj.AddPair('price', TJSONNumber.Create(Q.FieldByName('price').AsFloat));
      Obj.AddPair('quantity', TJSONNumber.Create(Q.FieldByName('quantity').AsFloat));
      Obj.AddPair('signal', Q.FieldByName('signal').AsString);
      Obj.AddPair('confidence', TJSONNumber.Create(Q.FieldByName('confidence').AsFloat));
      Obj.AddPair('orderId', TJSONNumber.Create(Q.FieldByName('order_id').AsLargeInt));
      Result.AddElement(Obj);
      Q.Next;
    end;
  finally
    Q.Free;
  end;
end;

function TDatabase.GetTradedSymbols: TArray<string>;
var
  Q: TUniQuery;
  List: TList<string>;
begin
  List := TList<string>.Create;
  try
    Q := TUniQuery.Create(nil);
    try
      Q.Connection := FConn;
      Q.SQL.Text := 'SELECT DISTINCT symbol FROM trades ORDER BY symbol';
      Q.Open;
      while not Q.Eof do
      begin
        List.Add(Q.FieldByName('symbol').AsString);
        Q.Next;
      end;
    finally
      Q.Free;
    end;
    Result := List.ToArray;
  finally
    List.Free;
  end;
end;

procedure TDatabase.SavePosition(const Symbol: string; BuyPrice: Double;
  BuyTime: TDateTime; Quantity: Double; HighestPrice: Double);
var
  Q: TUniQuery;
begin
  if HighestPrice <= 0 then HighestPrice := BuyPrice;
  Q := TUniQuery.Create(nil);
  try
    Q.Connection := FConn;
    Q.SQL.Text :=
      'INSERT INTO open_positions (symbol, buy_price, buy_time, quantity, high_price) ' +
      'VALUES (:sym, :price, :btime, :qty, :hprice)';
    Q.ParamByName('sym').AsString := Symbol;
    Q.ParamByName('price').AsFloat := BuyPrice;
    Q.ParamByName('btime').AsString := FormatDateTime('yyyy-mm-dd hh:nn:ss', BuyTime);
    Q.ParamByName('qty').AsFloat := Quantity;
    Q.ParamByName('hprice').AsFloat := HighestPrice;
    Q.Execute;
  finally
    Q.Free;
  end;
end;

procedure TDatabase.DeletePosition(const Symbol: string);
var
  Q: TUniQuery;
begin
  Q := TUniQuery.Create(nil);
  try
    Q.Connection := FConn;
    // Deleta a posicao mais antiga do symbol (FIFO)
    Q.SQL.Text :=
      'DELETE FROM open_positions WHERE id = (' +
      '  SELECT id FROM open_positions WHERE symbol = :sym ORDER BY id ASC LIMIT 1' +
      ')';
    Q.ParamByName('sym').AsString := Symbol;
    Q.Execute;
  finally
    Q.Free;
  end;
end;

procedure TDatabase.DeleteAllPositions(const Symbol: string);
var
  Q: TUniQuery;
begin
  Q := TUniQuery.Create(nil);
  try
    Q.Connection := FConn;
    Q.SQL.Text := 'DELETE FROM open_positions WHERE symbol = :sym';
    Q.ParamByName('sym').AsString := Symbol;
    Q.Execute;
  finally
    Q.Free;
  end;
end;

function TDatabase.LoadPositions: TList<TOpenPosition>;
var
  Q: TUniQuery;
  Pos: TOpenPosition;
  FmtISO: TFormatSettings;
begin
  FmtISO := TFormatSettings.Create;
  FmtISO.DateSeparator := '-';
  FmtISO.TimeSeparator := ':';
  FmtISO.ShortDateFormat := 'yyyy-mm-dd';
  FmtISO.LongTimeFormat := 'hh:nn:ss';

  Result := TList<TOpenPosition>.Create;
  Q := TUniQuery.Create(nil);
  try
    Q.Connection := FConn;
    Q.SQL.Text := 'SELECT * FROM open_positions ORDER BY id ASC';
    Q.Open;
    while not Q.Eof do
    begin
      Pos.Symbol := Q.FieldByName('symbol').AsString;
      Pos.BuyPrice := Q.FieldByName('buy_price').AsFloat;
      Pos.BuyTime := StrToDateTimeDef(Q.FieldByName('buy_time').AsString, Now, FmtISO);
      Pos.Quantity := Q.FieldByName('quantity').AsFloat;
      Pos.HighestPrice := Q.FieldByName('high_price').AsFloat;
      if Pos.HighestPrice <= 0 then Pos.HighestPrice := Pos.BuyPrice;
      Result.Add(Pos);
      Q.Next;
    end;
  finally
    Q.Free;
  end;
end;

procedure TDatabase.UpdatePositionHighPrice(const Symbol: string; HighPrice: Double);
var
  Q: TUniQuery;
begin
  Q := TUniQuery.Create(nil);
  try
    Q.Connection := FConn;
    Q.SQL.Text :=
      'UPDATE open_positions SET high_price = :hp WHERE symbol = :sym AND high_price < :hp';
    Q.ParamByName('hp').AsFloat := HighPrice;
    Q.ParamByName('sym').AsString := Symbol;
    Q.Execute;
  finally
    Q.Free;
  end;
end;

procedure TDatabase.SaveWalletSnapshot(TotalUSDT: Double; Timestamp: TDateTime);
var
  Q: TUniQuery;
begin
  Q := TUniQuery.Create(nil);
  try
    Q.Connection := FConn;
    Q.SQL.Text :=
      'INSERT INTO wallet_snapshots (timestamp, total_usdt) VALUES (:ts, :total)';
    Q.ParamByName('ts').AsString := FormatDateTime('yyyy-mm-dd hh:nn:ss', Timestamp);
    Q.ParamByName('total').AsFloat := TotalUSDT;
    Q.Execute;
  finally
    Q.Free;
  end;
end;

function TDatabase.LoadWalletSnapshots(MaxRecords: Integer): TJSONArray;
var
  Q: TUniQuery;
  Obj: TJSONObject;
begin
  Result := TJSONArray.Create;
  Q := TUniQuery.Create(nil);
  try
    Q.Connection := FConn;
    // Pega os ultimos N registros, ordenados do mais antigo ao mais recente
    Q.SQL.Text :=
      'SELECT * FROM (' +
      '  SELECT timestamp, total_usdt FROM wallet_snapshots ORDER BY id DESC LIMIT :lim' +
      ') sub ORDER BY timestamp ASC';
    Q.ParamByName('lim').AsInteger := MaxRecords;
    Q.Open;
    while not Q.Eof do
    begin
      Obj := TJSONObject.Create;
      Obj.AddPair('timestamp', Q.FieldByName('timestamp').AsString);
      Obj.AddPair('totalUSDT', TJSONNumber.Create(Q.FieldByName('total_usdt').AsFloat));
      Result.AddElement(Obj);
      Q.Next;
    end;
  finally
    Q.Free;
  end;
end;

procedure TDatabase.SaveAIAnalysis(const Symbol: string; const Analysis: TAIAnalysis);
var
  Q: TUniQuery;
begin
  Q := TUniQuery.Create(nil);
  try
    Q.Connection := FConn;
    Q.SQL.Text :=
      'INSERT OR REPLACE INTO ai_cache (symbol, signal, confidence, reasoning, entry, stop_loss, take_profit, timestamp) ' +
      'VALUES (:sym, :sig, :conf, :reason, :entry, :sl, :tp, :ts)';
    Q.ParamByName('sym').AsString := Symbol;
    Q.ParamByName('sig').AsString := SignalToStrEN(Analysis.Signal);
    Q.ParamByName('conf').AsFloat := Analysis.Confidence;
    Q.ParamByName('reason').AsString := Analysis.Reasoning;
    Q.ParamByName('entry').AsFloat := Analysis.SuggestedEntry;
    Q.ParamByName('sl').AsFloat := Analysis.SuggestedStopLoss;
    Q.ParamByName('tp').AsFloat := Analysis.SuggestedTakeProfit;
    Q.ParamByName('ts').AsString := FormatDateTime('yyyy-mm-dd hh:nn:ss', Analysis.Timestamp);
    Q.Execute;
  finally
    Q.Free;
  end;
end;

function TDatabase.LoadAICache: TDictionary<string, TAIAnalysis>;
var
  Q: TUniQuery;
  A: TAIAnalysis;
  Fmt: TFormatSettings;
begin
  Fmt := TFormatSettings.Create;
  Fmt.DateSeparator := '-';
  Fmt.TimeSeparator := ':';
  Fmt.ShortDateFormat := 'yyyy-mm-dd';
  Fmt.ShortTimeFormat := 'hh:nn:ss';

  Result := TDictionary<string, TAIAnalysis>.Create;
  Q := TUniQuery.Create(nil);
  try
    Q.Connection := FConn;
    Q.SQL.Text := 'SELECT * FROM ai_cache';
    Q.Open;
    while not Q.Eof do
    begin
      try
        A := Default(TAIAnalysis);
        A.Signal := StrENToSignal(Q.FieldByName('signal').AsString);
        A.Confidence := Q.FieldByName('confidence').AsFloat;
        A.Reasoning := Q.FieldByName('reasoning').AsString;
        A.SuggestedEntry := Q.FieldByName('entry').AsFloat;
        A.SuggestedStopLoss := Q.FieldByName('stop_loss').AsFloat;
        A.SuggestedTakeProfit := Q.FieldByName('take_profit').AsFloat;
        A.Timestamp := StrToDateTimeDef(Q.FieldByName('timestamp').AsString, Now, Fmt);
        Result.AddOrSetValue(Q.FieldByName('symbol').AsString, A);
      except
        // Ignora registros com erro (ex: encoding) e continua
      end;
      Q.Next;
    end;
  finally
    Q.Free;
  end;
end;

end.
