unit uMain;

interface

uses
  Winapi.Windows, Winapi.Messages, System.SysUtils, System.Variants,
  System.Classes, System.UITypes, System.DateUtils, System.Math,
  System.JSON, System.IniFiles, System.IOUtils, System.Diagnostics, System.StrUtils,
  System.Net.HttpClient, System.Net.URLClient, System.Net.Mime, System.NetEncoding,
  Vcl.Graphics, Vcl.Controls, Vcl.Forms, Vcl.Dialogs, Vcl.ExtCtrls,
  Vcl.StdCtrls, Vcl.Edge, WebView2, ActiveX,
  System.Generics.Collections, System.Generics.Defaults,
  uTypes, uBinanceAPI, uTechnicalAnalysis, uAIEngine, uDatabase, uGeneticOptimizer,
  UniProvider, SQLiteUniProvider, Data.DB, DBAccess, Uni;

type
  TfrmMain = class(TForm)
    lblStatus: TLabel;
    procedure FormCreate(Sender: TObject);
    procedure FormDestroy(Sender: TObject);
    procedure FormClose(Sender: TObject; var Action: TCloseAction);
  private
    FEdge: TEdgeBrowser;
    FTimerScan: TTimer;
    FTimerPrice: TTimer;
    FTimerBot: TTimer;
    FTimerWallet: TTimer;
    FBinance: TBinanceAPI;
    FAIEngine: TAIEngine;
    FDB: TDatabase;

    FConfig: TJSONObject;
    FPageReady: Boolean;
    FBotRunning: Boolean;
    FAnalyzing: Boolean;       // DoAnalyze manual do usuario
    FBotCycleActive: Boolean;  // DoBotAnalyzeAll em andamento
    FScanning: Boolean;
    FHtmlFilePath: string;

    FTopCoins: TCoinRecoveryArray;
    FSelectedSymbol: string;
    FBotCoinIndex: Integer;  // Indice de rotacao do bot pelas top coins
    FLastAutoTradeSignal: TTradeSignal;  // Evita trades repetidos no mesmo sinal
    FLastTradeTime: TDictionary<string, TDateTime>;  // Cooldown entre trades por symbol
    FSymbolFirstEntry: TDictionary<string, TDateTime>;  // Primeira entrada por symbol (sobrevive ciclos compra/venda)
    FLateralBlacklist: TDictionary<string, TDateTime>;  // Symbols vendidos por lateralizacao (bloqueio de recompra)
    FSellingSymbols: TDictionary<string, Boolean>;      // Guard: impede vendas duplicadas do mesmo symbol
    FAICacheLoadCount: Integer;
    FOptimizer: TGeneticOptimizer;
    FOptimizing: Boolean;
    FRefreshingWallet: Boolean;
    FApiKeyValid: Boolean;
    FOpenPositions: TList<TOpenPosition>;
    FLastCandles: TCandleArray;
    FLastIndicators: TTechnicalIndicators;
    FLastAnalysis: TAIAnalysis;
    FAICache: TDictionary<string, TAIAnalysis>;

    // AI Stats
    FAITotalCalls: Integer;
    FAITotalTokensIn: Int64;
    FAITotalTokensOut: Int64;
    FAITotalTimeMs: Int64;
    procedure SendAIStats;

    // Edge
    procedure EdgeCreateWebViewCompleted(Sender: TCustomEdgeBrowser; AResult: HRESULT);
    procedure EdgeWebMessageReceived(Sender: TCustomEdgeBrowser; Args: TWebMessageReceivedEventArgs);

    // JS bridge
    procedure SendToJS(const Action: string; Data: TJSONObject = nil);
    procedure HandleJSMessage(const Action: string; Data: TJSONObject);

    // Scanner
    procedure DoScan;
    procedure DoSelectCoin(const Symbol: string);

    // Actions
    procedure DoAnalyze;
    procedure DoBuy(Amount: Double);
    procedure DoSell(Amount: Double);
    procedure DoStartBot;
    procedure DoStopBot;
    procedure DoTestConnection;
    procedure DoSaveConfig(Data: TJSONObject);
    procedure DoPageReady;
    procedure DoRefreshWallet;
    procedure CheckLateralPositions;
    procedure CheckStopLossTakeProfit;
    procedure CheckDCA;
    procedure DoBotAnalyzeAll;
    procedure DoTestAI(Data: TJSONObject);
    procedure DoOptimize;
    procedure DoCancelOptimize;
    procedure DoApplyOptimizedParams(Data: TJSONObject);
    procedure DoLoadBinanceTrades;
    procedure DoCoinHistory(const Symbol: string);
    procedure DoGetAllSymbols;
    procedure DoRegisterPosition(const Symbol: string);
    procedure DoChatMessage(Data: TJSONObject);
    function ExecuteChatTool(const AName, AArgs, APosSnap: string): string;

    // Updates
    procedure UpdatePrice;
    procedure UpdateBalance;
    procedure SendTopCoins;
    procedure SendCandles;
    procedure SendIndicators;
    procedure SendSignal;

    // Telegram
    procedure SendTelegram(const Msg: string);
    procedure SendTelegramPhoto(const Caption, Base64Png: string);
    procedure SendTelegramWithChart(const Caption, Symbol: string);

    // Log
    procedure AddLog(const Tag, Msg: string);
    procedure SetStatus(const Msg: string);

    // Config
    procedure LoadConfig;
    procedure SaveConfig;
    function GetCfgStr(const Key, Default: string): string;
    function GetCfgBool(const Key: string; Default: Boolean): Boolean;
    function GetCfgDbl(const Key: string; Default: Double): Double;
    function GetInterval: string;

    // Timers
    procedure OnTimerScan(Sender: TObject);
    procedure OnTimerPrice(Sender: TObject);
    procedure OnTimerBot(Sender: TObject);
    procedure OnTimerWallet(Sender: TObject);

    // HTML
    procedure LoadHtmlFromFile;
  end;

var
  frmMain: TfrmMain;

implementation

{$R *.dfm}

const
  CONFIG_FILE = 'BinanceTrader.ini';

function DbPathForMode(IsTestnet: Boolean): string;
begin
  if IsTestnet then
    Result := ExtractFilePath(Application.ExeName) + 'BinanceBot_testnet.db'
  else
    Result := ExtractFilePath(Application.ExeName) + 'BinanceBot_prod.db';
end;

function HoursToWindowSize(Hours: Integer): string;
var Days: Integer;
begin
  if Hours < 1 then Hours := 24;
  if Hours > 168 then Hours := 168;
  if Hours <= 23 then
    Result := IntToStr(Hours) + 'h'
  else begin
    Days := Hours div 24;
    if Days < 1 then Days := 1;
    if Days > 7 then Days := 7;
    Result := IntToStr(Days) + 'd';
  end;
end;

{ ================================================================
  FORM LIFECYCLE
  ================================================================ }

procedure TfrmMain.FormCreate(Sender: TObject);
var
  LDataFolder: string;
begin
  SetDllDirectory('c:\colosso\prod\dlls');
  FPageReady := False;
  FBotRunning := False;
  FAnalyzing := False;
  FBotCycleActive := False;
  FScanning := False;
  FLastAutoTradeSignal := tsHold;
  FBotCoinIndex := 0;
  FApiKeyValid := False;
  FSelectedSymbol := '';
  FConfig := TJSONObject.Create;
  FOpenPositions := TList<TOpenPosition>.Create;
  FLastTradeTime := TDictionary<string, TDateTime>.Create;
  FSymbolFirstEntry := TDictionary<string, TDateTime>.Create;
  FLateralBlacklist := TDictionary<string, TDateTime>.Create;
  FSellingSymbols := TDictionary<string, Boolean>.Create;
  FAICache := TDictionary<string, TAIAnalysis>.Create;  // Sera preenchido do DB apos FDB.Create
  FOptimizer := nil;
  FOptimizing := False;

  SetStatus('Localizando HTML...');

  // 1. Localiza arquivo HTML
  LoadHtmlFromFile;
  if FHtmlFilePath = '' then
  begin
    SetStatus('ERRO: index.html nao encontrado!');
    ShowMessage(
      'Arquivo index.html nao encontrado!' + sLineBreak + sLineBreak +
      'Coloque index.html ao lado do executavel:' + sLineBreak +
      ExtractFilePath(Application.ExeName) + 'index.html');
    Exit;
  end;

  SetStatus('HTML: ' + FHtmlFilePath + ' - Iniciando WebView2...');

  // 2. Pasta de cache do WebView2
  LDataFolder := TPath.Combine(ExtractFilePath(Application.ExeName), 'EdgeCache');
  ForceDirectories(LDataFolder);

  // 3. Cria TEdgeBrowser em RUNTIME
  //    Ordem critica: Create -> UserDataFolder -> Eventos -> Parent
  FEdge := TEdgeBrowser.Create(Self);
  FEdge.UserDataFolder := LDataFolder;
  FEdge.OnCreateWebViewCompleted := EdgeCreateWebViewCompleted;
  FEdge.OnWebMessageReceived := EdgeWebMessageReceived;
  FEdge.Align := alClient;
  FEdge.Parent := Self;   // Dispara inicializacao do WebView2
  FEdge.Navigate('about.blank');

  // 4. Timers
  FTimerScan := TTimer.Create(Self);
  FTimerScan.Interval := 60000;  // Scan a cada 60s
  FTimerScan.Enabled := False;
  FTimerScan.OnTimer := OnTimerScan;

  FTimerPrice := TTimer.Create(Self);
  FTimerPrice.Interval := 5000;
  FTimerPrice.Enabled := False;
  FTimerPrice.OnTimer := OnTimerPrice;

  FTimerBot := TTimer.Create(Self);
  FTimerBot.Interval := 300000;
  FTimerBot.Enabled := False;
  FTimerBot.OnTimer := OnTimerBot;

  FTimerWallet := TTimer.Create(Self);
  FTimerWallet.Interval := 1800000;  // 30 min padrao para snapshot da carteira
  FTimerWallet.Enabled := False;
  FTimerWallet.OnTimer := OnTimerWallet;

  // 5. Config e APIs
  LoadConfig;

  // Banco de dados SQLite
  FDB := TDatabase.Create(DbPathForMode(GetCfgBool('testnet', True)));
  // Carregar posicoes abertas do banco
  FreeAndNil(FOpenPositions);
  FOpenPositions := FDB.LoadPositions;
  // Carregar cache de analises IA do banco
  FreeAndNil(FAICache);
  try
    FAICache := FDB.LoadAICache;
  except
    on E: Exception do
    begin
      FAICache := TDictionary<string, TAIAnalysis>.Create;
    end;
  end;
  FAICacheLoadCount := FAICache.Count;  // salva para log posterior
  // Inicializa FirstEntry para posicoes carregadas do banco
  for var PI := 0 to FOpenPositions.Count - 1 do
    if not FSymbolFirstEntry.ContainsKey(FOpenPositions[PI].Symbol) then
      FSymbolFirstEntry.AddOrSetValue(FOpenPositions[PI].Symbol, FOpenPositions[PI].BuyTime);

  // Seleciona chaves conforme modo (testnet ou producao)
  if GetCfgBool('testnet', True) then
    FBinance := TBinanceAPI.Create(
      GetCfgStr('apiKeyTest', ''),
      GetCfgStr('secretKeyTest', ''),
      True)
  else
    FBinance := TBinanceAPI.Create(
      GetCfgStr('apiKeyProd', ''),
      GetCfgStr('secretKeyProd', ''),
      False);
  FBinance.OnLog := procedure(AMsg: string)
    begin
      TThread.Queue(nil, procedure begin AddLog('Binance', AMsg); end);
    end;

  FAIEngine := TAIEngine.Create(GetCfgStr('aiKey', ''), GetCfgStr('aiModel', 'gpt-4o-mini'));
  FAIEngine.UseVision := GetCfgBool('aiVision', False);
  FAIEngine.OnLog := procedure(AMsg: string)
    begin
      TThread.Queue(nil, procedure begin AddLog('IA', AMsg); end);
    end;
  var LURL := GetCfgStr('aiBaseURL', '');
  if LURL <> '' then
    FAIEngine.BaseURL := LURL;
end;

procedure TfrmMain.FormDestroy(Sender: TObject);
begin
  if FTimerScan <> nil then FTimerScan.Enabled := False;
  if FTimerPrice <> nil then FTimerPrice.Enabled := False;
  if FTimerBot <> nil then FTimerBot.Enabled := False;
  if FTimerWallet <> nil then FTimerWallet.Enabled := False;
  FreeAndNil(FBinance);
  FreeAndNil(FAIEngine);
  FreeAndNil(FConfig);
  FreeAndNil(FOpenPositions);
  FreeAndNil(FLastTradeTime);
  FreeAndNil(FSymbolFirstEntry);
  FreeAndNil(FLateralBlacklist);
  FreeAndNil(FSellingSymbols);
  FreeAndNil(FAICache);
  FreeAndNil(FDB);
end;

procedure TfrmMain.FormClose(Sender: TObject; var Action: TCloseAction);
begin
  SaveConfig;
end;

procedure TfrmMain.SetStatus(const Msg: string);
begin
  lblStatus.Caption := Msg;
  lblStatus.Update;
end;

{ ================================================================
  HTML FILE LOCATOR
  ================================================================ }

procedure TfrmMain.LoadHtmlFromFile;
var
  LExe, LPath: string;
  LPaths: TArray<string>;
  I: Integer;
begin
  FHtmlFilePath := '';
  LExe := ExtractFilePath(Application.ExeName);

  LPaths := TArray<string>.Create(
    TPath.Combine(LExe, 'index.html'),
    TPath.Combine(LExe, 'html\index.html'),
    TPath.Combine(LExe, '..\index.html'),
    TPath.Combine(LExe, '..\html\index.html')
  );

  for I := 0 to High(LPaths) do
  begin
    LPath := TPath.GetFullPath(LPaths[I]);
    if FileExists(LPath) then
    begin
      FHtmlFilePath := LPath;
      Exit;
    end;
  end;
end;

{ ================================================================
  TEDGEBROWSER EVENTS
  ================================================================ }

procedure TfrmMain.EdgeCreateWebViewCompleted(Sender: TCustomEdgeBrowser;
  AResult: HRESULT);
var
  LFileURL: string;
begin
  if not Succeeded(AResult) then
  begin
    SetStatus('ERRO WebView2: 0x' + IntToHex(AResult, 8));
    ShowMessage(
      'Falha ao inicializar WebView2!' + sLineBreak +
      'Codigo: 0x' + IntToHex(AResult, 8) + sLineBreak + sLineBreak +
      'Instale o WebView2 Runtime:' + sLineBreak +
      'https://go.microsoft.com/fwlink/p/?LinkId=2124703');
    Exit;
  end;

  SetStatus('WebView2 OK! Navegando para ' + FHtmlFilePath);

  // Navega para o arquivo HTML via file:// URL
  if FHtmlFilePath <> '' then
  begin
    LFileURL := 'file:///' + StringReplace(FHtmlFilePath, '\', '/', [rfReplaceAll]);
    FEdge.Navigate(LFileURL);
  end
  else
    FEdge.NavigateToString(
      '<html><body style="background:#0b0e11;color:#f0b90b;' +
      'display:flex;align-items:center;justify-content:center;height:100vh;' +
      'font-family:sans-serif;font-size:24px;">index.html nao encontrado</body></html>');
end;

procedure TfrmMain.EdgeWebMessageReceived(Sender: TCustomEdgeBrowser;
  Args: TWebMessageReceivedEventArgs);
var
  LMsgPtr: PWideChar;
  LMsgStr: string;
  LJson: TJSONValue;
  LObj: TJSONObject;
  LAction: string;
  LData: TJSONValue;
begin
  if not Succeeded(Args.ArgsInterface.TryGetWebMessageAsString(LMsgPtr)) then
    Exit;

  LMsgStr := string(LMsgPtr);
  CoTaskMemFree(LMsgPtr);

  LJson := TJSONObject.ParseJSONValue(LMsgStr);
  if (LJson = nil) or not (LJson is TJSONObject) then
  begin
    LJson.Free;
    Exit;
  end;

  LObj := TJSONObject(LJson);
  try
    LAction := LObj.GetValue<string>('action', '');
    if LAction = '' then Exit;

    LData := LObj.FindValue('data');
    if (LData <> nil) and (LData is TJSONObject) then
      HandleJSMessage(LAction, TJSONObject(LData))
    else
      HandleJSMessage(LAction, nil);
  finally
    LObj.Free;
  end;
end;

{ ================================================================
  JS BRIDGE:  Delphi --> JavaScript
  ================================================================ }

procedure TfrmMain.SendToJS(const Action: string; Data: TJSONObject);
var
  LMsg: TJSONObject;
  LOwnedData: TJSONObject;
  LScript: string;
begin
  if not FPageReady or (FEdge = nil) then Exit;

  LMsg := TJSONObject.Create;
  try
    LMsg.AddPair('action', Action);
    if Data <> nil then
      LOwnedData := Data.Clone as TJSONObject
    else
      LOwnedData := TJSONObject.Create;
    LMsg.AddPair('data', LOwnedData);

    LScript := 'try{handleDelphiMessage(' + LMsg.ToJSON + ');}catch(e){console.error("SendToJS:",e);}';
    FEdge.ExecuteScript(LScript);
  finally
    LMsg.Free;
  end;
end;

procedure TfrmMain.SendAIStats;
const
  // GPT-4o-mini pricing per 1M tokens (reference)
  PRICE_IN  = 0.15;  // $0.15 / 1M input tokens
  PRICE_OUT = 0.60;  // $0.60 / 1M output tokens
var
  D: TJSONObject;
  LAvgMs: Double;
  LCostIn, LCostOut, LCostTotal: Double;
begin
  if FAITotalCalls = 0 then Exit;
  LAvgMs := FAITotalTimeMs / FAITotalCalls;
  LCostIn := (FAITotalTokensIn / 1000000) * PRICE_IN;
  LCostOut := (FAITotalTokensOut / 1000000) * PRICE_OUT;
  LCostTotal := LCostIn + LCostOut;

  D := TJSONObject.Create;
  D.AddPair('calls', TJSONNumber.Create(FAITotalCalls));
  D.AddPair('tokensIn', TJSONNumber.Create(FAITotalTokensIn));
  D.AddPair('tokensOut', TJSONNumber.Create(FAITotalTokensOut));
  D.AddPair('avgTimeSec', TJSONNumber.Create(Round(LAvgMs) / 1000));
  D.AddPair('costTotal', TJSONNumber.Create(LCostTotal));
  D.AddPair('costAvg', TJSONNumber.Create(LCostTotal / FAITotalCalls));
  SendToJS('aiStats', D);
end;

{ ================================================================
  JS BRIDGE:  JavaScript --> Delphi
  ================================================================ }

procedure TfrmMain.HandleJSMessage(const Action: string; Data: TJSONObject);
begin
  if Action = 'pageReady' then
    DoPageReady
  else if Action = 'scanNow' then
    DoScan
  else if Action = 'selectCoin' then
  begin
    if Data <> nil then
      DoSelectCoin(Data.GetValue<string>('symbol', ''))
  end
  else if Action = 'analyze' then
    DoAnalyze
  else if Action = 'buy' then
  begin
    if Data <> nil then
      DoBuy(Data.GetValue<Double>('amount', 0))
    else
      DoBuy(GetCfgDbl('tradeAmount', 100));
  end
  else if Action = 'sell' then
  begin
    if Data <> nil then
      DoSell(Data.GetValue<Double>('amount', 0))
    else
      DoSell(GetCfgDbl('tradeAmount', 100));
  end
  else if Action = 'startBot' then DoStartBot
  else if Action = 'stopBot' then DoStopBot
  else if Action = 'testConnection' then DoTestConnection
  else if Action = 'saveConfig' then DoSaveConfig(Data)
  else if Action = 'refreshWallet' then DoRefreshWallet
  else if Action = 'testAI' then DoTestAI(Data)
  else if Action = 'startOptimize' then DoOptimize
  else if Action = 'cancelOptimize' then DoCancelOptimize
  else if Action = 'applyOptimizedParams' then DoApplyOptimizedParams(Data)
  else if Action = 'loadBinanceTrades' then DoLoadBinanceTrades
  else if Action = 'coinHistory' then
  begin
    if Data <> nil then
      DoCoinHistory(Data.GetValue<string>('symbol', ''));
  end
  else if Action = 'getAllSymbols' then
    DoGetAllSymbols
  else if Action = 'registerPosition' then
  begin
    if Data <> nil then
      DoRegisterPosition(Data.GetValue<string>('symbol', ''));
  end
  else if Action = 'chatMessage' then
    DoChatMessage(Data)
  else if Action = 'sendChartTelegram' then
  begin
    var LChartSym := '';
    if Data <> nil then
      LChartSym := Data.GetValue<string>('symbol', '');
    if LChartSym = '' then
      LChartSym := FSelectedSymbol;
    if LChartSym = '' then
      AddLog('Telegram', 'Nenhuma moeda selecionada!')
    else begin
      AddLog('Telegram', 'Enviando grafico de ' + LChartSym + '...');
      var LPrice := FLastIndicators.CurrentPrice;
      var LChange := FLastIndicators.PriceChange24h;
      var LCaption := Format('%s | $%s | %s%%',
        [LChartSym,
         FormatFloat('0.########', LPrice, FmtDot),
         FormatFloat('0.00', LChange, FmtDot)]);
      SendTelegramWithChart(LCaption, LChartSym);
    end;
  end
  else if Action = 'testTelegram' then
  begin
    // Forca envio mesmo se desabilitado (para testar token/chatId)
    var LTgToken := GetCfgStr('telegramToken', '');
    var LTgChat := GetCfgStr('telegramChatId', '');
    if (LTgToken = '') or (LTgChat = '') then
      AddLog('Telegram', 'Preencha o Token e Chat ID antes de testar!')
    else begin
      TThread.CreateAnonymousThread(procedure
      var Http: THTTPClient; Body: TStringStream; JB: TJSONObject;
      begin
        Http := THTTPClient.Create;
        try
          Http.ConnectionTimeout := 5000;
          Http.ResponseTimeout := 10000;
          JB := TJSONObject.Create;
          try
            JB.AddPair('chat_id', LTgChat);
            JB.AddPair('text', '&#x2705; <b>Teste OK!</b>'#10'Bot Binance conectado ao Telegram.');
            JB.AddPair('parse_mode', 'HTML');
            Body := TStringStream.Create(JB.ToJSON, TEncoding.UTF8);
            try
              Http.Post(
                'https://api.telegram.org/bot' + LTgToken + '/sendMessage',
                Body, nil,
                [TNetHeader.Create('Content-Type', 'application/json')]);
            finally
              Body.Free;
            end;
          finally
            JB.Free;
          end;
        finally
          Http.Free;
        end;
        TThread.Queue(nil, procedure begin AddLog('Telegram', 'Mensagem de teste enviada!'); end);
      end).Start;
    end;
  end;
end;

{ ================================================================
  CHAT TOOL EXECUTOR
  ================================================================ }

function TfrmMain.ExecuteChatTool(const AName, AArgs, APosSnap: string): string;
type
  TCoinRank = record
    Symbol: string;
    Change: Double;
  end;
var
  JArgs: TJSONObject;
  Sym, Interval: string;
  Limit, I, Count: Integer;
  Price: Double;
  Ticker: TJSONObject;
  Tickers: TJSONArray;
  Candles: TCandleArray;
  Indic: TTechnicalIndicators;
  Balances: TAssetBalanceArray;
  Trades: TJSONArray;
  FmtD: TFormatSettings;
  Coins: TArray<TCoinRank>;
  Coin: TCoinRank;
begin
  Result := '';
  FmtD := TFormatSettings.Create;
  FmtD.DecimalSeparator := '.';

  JArgs := nil;
  try
    if AArgs <> '' then
      JArgs := TJSONObject(TJSONObject.ParseJSONValue(AArgs));
  except
    JArgs := nil;
  end;

  try
    // === get_price ===
    if AName = 'get_price' then
    begin
      Sym := '';
      if JArgs <> nil then Sym := JArgs.GetValue<string>('symbol', '');
      if Sym = '' then begin Result := 'Erro: symbol obrigatorio'; Exit; end;
      Sym := UpperCase(Sym);
      if not Sym.EndsWith('USDT') then Sym := Sym + 'USDT';
      Price := FBinance.GetPrice(Sym);
      if Price > 0 then
        Result := Format('%s: $%s USDT', [Sym, FormatFloat('0.########', Price, FmtD)])
      else
        Result := 'Nao foi possivel obter o preco de ' + Sym;
    end

    // === get_ticker_24h ===
    else if AName = 'get_ticker_24h' then
    begin
      Sym := '';
      if JArgs <> nil then Sym := JArgs.GetValue<string>('symbol', '');
      if Sym = '' then begin Result := 'Erro: symbol obrigatorio'; Exit; end;
      Sym := UpperCase(Sym);
      if not Sym.EndsWith('USDT') then Sym := Sym + 'USDT';
      Ticker := FBinance.Get24hTicker(Sym);
      try
        if Ticker <> nil then
          Result := Format(
            '%s 24h: preco=$%s, variacao=%s%%, ' +
            'high=$%s, low=$%s, volume=%s',
            [Sym,
             Ticker.GetValue<string>('lastPrice', '?'),
             Ticker.GetValue<string>('priceChangePercent', '?'),
             Ticker.GetValue<string>('highPrice', '?'),
             Ticker.GetValue<string>('lowPrice', '?'),
             Ticker.GetValue<string>('volume', '?')])
        else
          Result := 'Nao foi possivel obter ticker 24h de ' + Sym;
      finally
        Ticker.Free;
      end;
    end

    // === get_top_gainers ===
    else if AName = 'get_top_gainers' then
    begin
      Limit := 10;
      if (JArgs <> nil) and (JArgs.GetValue('limit') <> nil) then
        Limit := JArgs.GetValue<Integer>('limit', 10);
      if Limit > 25 then Limit := 25;
      Tickers := FBinance.GetAll24hTickers;
      try
        if (Tickers <> nil) and (Tickers.Count > 0) then
        begin
          SetLength(Coins, 0);
          for I := 0 to Tickers.Count - 1 do
          begin
            Sym := TJSONObject(Tickers.Items[I]).GetValue<string>('symbol', '');
            if not Sym.EndsWith('USDT') then Continue;
            Coin.Symbol := Sym;
            Coin.Change := StrToFloatDef(
              TJSONObject(Tickers.Items[I]).GetValue<string>('priceChangePercent', '0'), 0, FmtD);
            SetLength(Coins, Length(Coins) + 1);
            Coins[High(Coins)] := Coin;
          end;
          // Sort descending
          TArray.Sort<TCoinRank>(Coins, TComparer<TCoinRank>.Construct(
            function(const A, B: TCoinRank): Integer
            begin Result := CompareValue(B.Change, A.Change); end));
          Result := 'Top gainers 24h:' + #13#10;
          Count := Min(Limit, Length(Coins));
          for I := 0 to Count - 1 do
            Result := Result + Format('%d. %s: %s%%', [I+1, Coins[I].Symbol,
              FormatFloat('0.##', Coins[I].Change, FmtD)]) + #13#10;
        end
        else
          Result := 'Nao foi possivel obter dados de tickers.';
      finally
        Tickers.Free;
      end;
    end

    // === get_top_losers ===
    else if AName = 'get_top_losers' then
    begin
      Limit := 10;
      if (JArgs <> nil) and (JArgs.GetValue('limit') <> nil) then
        Limit := JArgs.GetValue<Integer>('limit', 10);
      if Limit > 25 then Limit := 25;
      Tickers := FBinance.GetAll24hTickers;
      try
        if (Tickers <> nil) and (Tickers.Count > 0) then
        begin
          SetLength(Coins, 0);
          for I := 0 to Tickers.Count - 1 do
          begin
            Sym := TJSONObject(Tickers.Items[I]).GetValue<string>('symbol', '');
            if not Sym.EndsWith('USDT') then Continue;
            Coin.Symbol := Sym;
            Coin.Change := StrToFloatDef(
              TJSONObject(Tickers.Items[I]).GetValue<string>('priceChangePercent', '0'), 0, FmtD);
            SetLength(Coins, Length(Coins) + 1);
            Coins[High(Coins)] := Coin;
          end;
          // Sort ascending (most negative first)
          TArray.Sort<TCoinRank>(Coins, TComparer<TCoinRank>.Construct(
            function(const A, B: TCoinRank): Integer
            begin Result := CompareValue(A.Change, B.Change); end));
          Result := 'Top losers 24h:' + #13#10;
          Count := Min(Limit, Length(Coins));
          for I := 0 to Count - 1 do
            Result := Result + Format('%d. %s: %s%%', [I+1, Coins[I].Symbol,
              FormatFloat('0.##', Coins[I].Change, FmtD)]) + #13#10;
        end
        else
          Result := 'Nao foi possivel obter dados de tickers.';
      finally
        Tickers.Free;
      end;
    end

    // === get_technical_indicators ===
    else if AName = 'get_technical_indicators' then
    begin
      Sym := '';
      Interval := '1h';
      if JArgs <> nil then
      begin
        Sym := JArgs.GetValue<string>('symbol', '');
        Interval := JArgs.GetValue<string>('interval', '1h');
      end;
      if Sym = '' then begin Result := 'Erro: symbol obrigatorio'; Exit; end;
      Sym := UpperCase(Sym);
      if not Sym.EndsWith('USDT') then Sym := Sym + 'USDT';
      Candles := FBinance.GetKlines(Sym, Interval, 100);
      if Length(Candles) >= 26 then
      begin
        Indic := TTechnicalAnalysis.FullAnalysis(Candles);
        Indic.CurrentPrice := FBinance.GetPrice(Sym);
        Result := Format(
          'Indicadores de %s (%s):' + #13#10 +
          'Preco: $%s' + #13#10 +
          'RSI(14): %s' + #13#10 +
          'MACD: %s | Signal: %s | Hist: %s' + #13#10 +
          'SMA20: %s | SMA50: %s' + #13#10 +
          'EMA12: %s | EMA26: %s' + #13#10 +
          'Bollinger: %s / %s / %s' + #13#10 +
          'ATR(14): %s',
          [Sym, Interval,
           FormatFloat('0.########', Indic.CurrentPrice, FmtD),
           FormatFloat('0.##', Indic.RSI, FmtD),
           FormatFloat('0.########', Indic.MACD, FmtD),
           FormatFloat('0.########', Indic.MACDSignal, FmtD),
           FormatFloat('0.########', Indic.MACDHistogram, FmtD),
           FormatFloat('0.########', Indic.SMA20, FmtD),
           FormatFloat('0.########', Indic.SMA50, FmtD),
           FormatFloat('0.########', Indic.EMA12, FmtD),
           FormatFloat('0.########', Indic.EMA26, FmtD),
           FormatFloat('0.########', Indic.BollingerUpper, FmtD),
           FormatFloat('0.########', Indic.BollingerMiddle, FmtD),
           FormatFloat('0.########', Indic.BollingerLower, FmtD),
           FormatFloat('0.########', Indic.ATR, FmtD)]);
      end
      else
        Result := 'Dados insuficientes para calcular indicadores de ' + Sym;
    end

    // === get_klines ===
    else if AName = 'get_klines' then
    begin
      Sym := '';
      Interval := '1h';
      Limit := 20;
      if JArgs <> nil then
      begin
        Sym := JArgs.GetValue<string>('symbol', '');
        Interval := JArgs.GetValue<string>('interval', '1h');
        Limit := JArgs.GetValue<Integer>('limit', 20);
      end;
      if Sym = '' then begin Result := 'Erro: symbol obrigatorio'; Exit; end;
      Sym := UpperCase(Sym);
      if not Sym.EndsWith('USDT') then Sym := Sym + 'USDT';
      if Limit > 100 then Limit := 100;
      Candles := FBinance.GetKlines(Sym, Interval, Limit);
      if Length(Candles) > 0 then
      begin
        Result := Format('Candles %s %s (ultimos %d):', [Sym, Interval, Length(Candles)]) + #13#10;
        for I := 0 to High(Candles) do
          Result := Result + Format('%s O:%s H:%s L:%s C:%s V:%s',
            [FormatDateTime('dd/mm hh:nn', Candles[I].OpenTime),
             FormatFloat('0.####', Candles[I].Open, FmtD),
             FormatFloat('0.####', Candles[I].High, FmtD),
             FormatFloat('0.####', Candles[I].Low, FmtD),
             FormatFloat('0.####', Candles[I].Close, FmtD),
             FormatFloat('0.##', Candles[I].Volume, FmtD)]) + #13#10;
      end
      else
        Result := 'Nenhum candle retornado para ' + Sym;
    end

    // === get_open_positions ===
    else if AName = 'get_open_positions' then
    begin
      if APosSnap <> '' then
        Result := 'Posicoes abertas:' + #13#10 + APosSnap
      else
        Result := 'Nenhuma posicao aberta no momento.';
    end

    // === get_wallet_balance ===
    else if AName = 'get_wallet_balance' then
    begin
      Balances := FBinance.GetAllBalances(0.0001);
      if Length(Balances) > 0 then
      begin
        Result := 'Saldos na carteira:' + #13#10;
        for I := 0 to High(Balances) do
          Result := Result + Format('- %s: livre=%s, bloqueado=%s',
            [Balances[I].Asset,
             FormatFloat('0.########', Balances[I].Free, FmtD),
             FormatFloat('0.########', Balances[I].Locked, FmtD)]) + #13#10;
      end
      else
        Result := 'Nenhum saldo encontrado ou erro ao consultar.';
    end

    // === get_trade_history ===
    else if AName = 'get_trade_history' then
    begin
      Sym := '';
      Limit := 20;
      if JArgs <> nil then
      begin
        Sym := JArgs.GetValue<string>('symbol', '');
        Limit := JArgs.GetValue<Integer>('limit', 20);
      end;
      if Sym = '' then
      begin
        // Retorna trades do banco local (todos os symbols)
        Trades := FDB.LoadTrades;
        try
          if Trades.Count > 0 then
          begin
            Result := 'Historico de trades (banco local):' + #13#10;
            Count := Min(Limit, Trades.Count);
            for I := 0 to Count - 1 do
              Result := Result + Format('- %s %s %s @ $%s qty=%s',
                [TJSONObject(Trades.Items[I]).GetValue<string>('timestamp', ''),
                 TJSONObject(Trades.Items[I]).GetValue<string>('side', ''),
                 TJSONObject(Trades.Items[I]).GetValue<string>('symbol', ''),
                 TJSONObject(Trades.Items[I]).GetValue<string>('price', '0'),
                 TJSONObject(Trades.Items[I]).GetValue<string>('quantity', '0')]) + #13#10;
          end
          else
            Result := 'Nenhum trade registrado no banco local.';
        finally
          Trades.Free;
        end;
      end
      else
      begin
        Sym := UpperCase(Sym);
        if not Sym.EndsWith('USDT') then Sym := Sym + 'USDT';
        if Limit > 50 then Limit := 50;
        Trades := FBinance.GetMyTrades(Sym, Limit);
        try
          if Trades.Count > 0 then
          begin
            Result := Format('Trades de %s na Binance (ultimos %d):', [Sym, Trades.Count]) + #13#10;
            for I := 0 to Trades.Count - 1 do
            begin
              var T := TJSONObject(Trades.Items[I]);
              var IsBuyer := T.GetValue<Boolean>('isBuyer', False);
              Result := Result + Format('- %s @ $%s qty=%s',
                [IfThen(IsBuyer, 'BUY', 'SELL'),
                 T.GetValue<string>('price', '0'),
                 T.GetValue<string>('qty', '0')]) + #13#10;
            end;
          end
          else
            Result := 'Nenhum trade encontrado para ' + Sym;
        finally
          Trades.Free;
        end;
      end;
    end

    // === get_order_book ===
    else if AName = 'get_order_book' then
    begin
      Sym := '';
      if JArgs <> nil then Sym := JArgs.GetValue<string>('symbol', '');
      if Sym = '' then begin Result := 'Erro: symbol obrigatorio'; Exit; end;
      Sym := UpperCase(Sym);
      if not Sym.EndsWith('USDT') then Sym := Sym + 'USDT';
      var OB := FBinance.GetOrderBook(Sym, 100);
      var Sentiment: string;
      if OB.Imbalance > 0.65 then Sentiment := 'FORTE PRESSAO COMPRADORA'
      else if OB.Imbalance > 0.55 then Sentiment := 'Leve pressao compradora'
      else if OB.Imbalance < 0.35 then Sentiment := 'FORTE PRESSAO VENDEDORA'
      else if OB.Imbalance < 0.45 then Sentiment := 'Leve pressao vendedora'
      else Sentiment := 'Neutro/Equilibrado';
      Result := Format(
        'Order Book de %s:' + #13#10 +
        'Sentimento: %s' + #13#10 +
        'Imbalance: %s (0.5=neutro, >0.6=bullish, <0.4=bearish)' + #13#10 +
        'Spread: %s%%' + #13#10 +
        'Best Bid: $%s | Best Ask: $%s' + #13#10 +
        'Volume Bids: $%s | Volume Asks: $%s' + #13#10 +
        'Maior Buy Wall: $%s @ preco $%s' + #13#10 +
        'Maior Sell Wall: $%s @ preco $%s',
        [Sym, Sentiment,
         FormatFloat('0.##', OB.Imbalance, FmtD),
         FormatFloat('0.####', OB.Spread, FmtD),
         FormatFloat('0.########', OB.BestBid, FmtD),
         FormatFloat('0.########', OB.BestAsk, FmtD),
         FormatFloat('0.##', OB.BidTotal, FmtD),
         FormatFloat('0.##', OB.AskTotal, FmtD),
         FormatFloat('0.##', OB.BiggestBidWall, FmtD),
         FormatFloat('0.########', OB.BiggestBidWallPrice, FmtD),
         FormatFloat('0.##', OB.BiggestAskWall, FmtD),
         FormatFloat('0.########', OB.BiggestAskWallPrice, FmtD)]);
    end

    else
      Result := 'Tool desconhecida: ' + AName;

  finally
    JArgs.Free;
  end;
end;

{ ================================================================
  CHAT MESSAGE
  ================================================================ }

procedure TfrmMain.DoChatMessage(Data: TJSONObject);
const
  CHAT_SYSTEM_PROMPT =
    'Voce e um especialista senior em trading de criptomoedas na Binance. ' +
    'Voce tem experiencia em analise tecnica (RSI, MACD, Bollinger, medias moveis, etc), ' +
    'analise fundamentalista, gestao de risco e estrategias de trading. ' +
    'Responda de forma direta e pratica. ' +
    'Formate sua resposta usando Markdown quando apropriado (negrito, listas, etc). ' +
    'Voce tem acesso a funcoes (tools) para buscar dados em tempo real da Binance. ' +
    'USE as tools SEMPRE que o usuario perguntar sobre precos, moedas, indicadores, carteira, rankings, etc. ' +
    'Nao invente dados - busque os dados reais usando as tools disponiveis. ' +
    'Fale em portugues brasileiro.';

  function MakeTool(const AName, ADesc, AParams: string): TJSONObject;
  var F, P: TJSONObject;
  begin
    Result := TJSONObject.Create;
    Result.AddPair('type', 'function');
    F := TJSONObject.Create;
    F.AddPair('name', AName);
    F.AddPair('description', ADesc);
    P := TJSONObject(TJSONObject.ParseJSONValue(AParams));
    if P <> nil then
      F.AddPair('parameters', P)
    else begin
      P := TJSONObject.Create;
      P.AddPair('type', 'object');
      P.AddPair('properties', TJSONObject.Create);
      F.AddPair('parameters', P);
    end;
    Result.AddPair('function', F);
  end;

  function BuildToolsArray: TJSONArray;
  var SymP, SymIntP, SymIntLimP, EmptyP, LimP, SymLimP: string;
  begin
    SymP := '{"type":"object",' +
      '"properties":{"symbol":{"type":"string",' +
      '"description":"Par, ex: BTCUSDT"}},' +
      '"required":["symbol"]}';
    SymIntP := '{"type":"object",' +
      '"properties":{"symbol":{"type":"string",' +
      '"description":"Par, ex: BTCUSDT"},' +
      '"interval":{"type":"string",' +
      '"description":"15m,1h,4h,1d"}},' +
      '"required":["symbol"]}';
    SymIntLimP := '{"type":"object",' +
      '"properties":{"symbol":{"type":"string",' +
      '"description":"Par, ex: BTCUSDT"},' +
      '"interval":{"type":"string",' +
      '"description":"1m,5m,15m,1h,4h,1d"},' +
      '"limit":{"type":"integer",' +
      '"description":"Qtd candles, max 100"}},' +
      '"required":["symbol"]}';
    EmptyP := '{"type":"object",' +
      '"properties":{},"required":[]}';
    LimP := '{"type":"object",' +
      '"properties":{"limit":{"type":"integer",' +
      '"description":"Qtd, padrao 10, max 25"}},' +
      '"required":[]}';
    SymLimP := '{"type":"object",' +
      '"properties":{"symbol":{"type":"string",' +
      '"description":"Par, ex: BTCUSDT"},' +
      '"limit":{"type":"integer",' +
      '"description":"Qtd, padrao 20, max 50"}},' +
      '"required":["symbol"]}';

    Result := TJSONArray.Create;
    Result.AddElement(MakeTool('get_price',
      'Obter preco atual de um par de cripto', SymP));
    Result.AddElement(MakeTool('get_ticker_24h',
      'Stats 24h: preco, variacao, volume, max, min', SymP));
    Result.AddElement(MakeTool('get_top_gainers',
      'Ranking moedas com maior alta 24h', LimP));
    Result.AddElement(MakeTool('get_top_losers',
      'Ranking moedas com maior queda 24h', LimP));
    Result.AddElement(MakeTool('get_technical_indicators',
      'Indicadores: RSI, MACD, Bollinger, SMA, EMA, ATR', SymIntP));
    Result.AddElement(MakeTool('get_klines',
      'Candles OHLCV historicos de um par', SymIntLimP));
    Result.AddElement(MakeTool('get_open_positions',
      'Posicoes abertas (compras) do usuario', EmptyP));
    Result.AddElement(MakeTool('get_wallet_balance',
      'Saldos da carteira na Binance', EmptyP));
    Result.AddElement(MakeTool('get_trade_history',
      'Historico de trades do usuario', SymLimP));
    Result.AddElement(MakeTool('get_order_book',
      'Livro de ofertas: imbalance, spread, walls de compra/venda, pressao do mercado', SymP));
  end;
var
  LHistoryVal: TJSONValue;
  LHistory: TJSONArray;
  LHistoryClone: TJSONArray;
  LPositionsSnap: string;
  LTools: TJSONArray;
  I: Integer;
  FmtDot: TFormatSettings;
begin
  if Data = nil then Exit;
  LHistoryVal := Data.GetValue('history');
  if (LHistoryVal <> nil) and (LHistoryVal is TJSONArray) then
    LHistory := TJSONArray(LHistoryVal)
  else
    LHistory := nil;

  FmtDot := TFormatSettings.Create;
  FmtDot.DecimalSeparator := '.';

  // Snapshot das posicoes abertas (main thread, para thread safety)
  LPositionsSnap := '';
  if (FOpenPositions <> nil) and (FOpenPositions.Count > 0) then
  begin
    for I := 0 to FOpenPositions.Count - 1 do
      LPositionsSnap := LPositionsSnap +
        Format('- %s: comprado a $%s, qty: %s, desde %s, high: $%s',
          [FOpenPositions[I].Symbol,
           FormatFloat('0.########', FOpenPositions[I].BuyPrice, FmtDot),
           FormatFloat('0.########', FOpenPositions[I].Quantity, FmtDot),
           FormatDateTime('dd/mm/yyyy hh:nn', FOpenPositions[I].BuyTime),
           FormatFloat('0.########', FOpenPositions[I].HighestPrice, FmtDot)]) + #13#10;
  end;

  // Construir tools array (main thread)
  LTools := BuildToolsArray;

  // Clone o historico completo
  LHistoryClone := TJSONArray.Create;
  if LHistory <> nil then
    for I := 0 to LHistory.Count - 1 do
    begin
      var Msg := TJSONObject.Create;
      Msg.AddPair('role', TJSONObject(LHistory.Items[I]).GetValue<string>('role', 'user'));
      Msg.AddPair('content', TJSONObject(LHistory.Items[I]).GetValue<string>('content', ''));
      LHistoryClone.AddElement(Msg);
    end;

  TThread.CreateAnonymousThread(procedure
  var
    LResp, LError: string;
    LRespData: TJSONObject;
    LTokensIn, LTokensOut: Integer;
  begin
    try
      LResp := FAIEngine.ChatWithTools(CHAT_SYSTEM_PROMPT, LHistoryClone, LTools,
        function(AName, AArgs: string): string
        begin
          Result := ExecuteChatTool(AName, AArgs, LPositionsSnap);
        end,
        procedure(AToolName: string)
        begin
          TThread.Queue(nil, procedure
          var LStatusData: TJSONObject;
          begin
            LStatusData := TJSONObject.Create;
            try
              LStatusData.AddPair('tool', AToolName);
              SendToJS('chatToolCall', LStatusData);
            finally
              LStatusData.Free;
            end;
          end);
        end);
      LTokensIn := FAIEngine.LastPromptTokens;
      LTokensOut := FAIEngine.LastCompletionTokens;
      LError := FAIEngine.LastError;
    finally
      LHistoryClone.Free;
      LTools.Free;
    end;

    TThread.Queue(nil, procedure
    begin
      LRespData := TJSONObject.Create;
      try
        if LResp <> '' then
          LRespData.AddPair('content', LResp)
        else
          LRespData.AddPair('content', 'Erro: ' + LError);
        LRespData.AddPair('tokensIn', TJSONNumber.Create(LTokensIn));
        LRespData.AddPair('tokensOut', TJSONNumber.Create(LTokensOut));
        SendToJS('chatResponse', LRespData);
      finally
        LRespData.Free;
      end;
    end);
  end).Start;
end;

{ ================================================================
  PAGE READY
  ================================================================ }

procedure TfrmMain.DoPageReady;
var
  LCfg, LConn: TJSONObject;
begin
  FPageReady := True;
  SetStatus('Pronto!');
  lblStatus.Visible := False;

  AddLog('Sistema', 'Interface carregada com sucesso!');
  AddLog('Sistema', Format('Cache IA: %d analises carregadas do banco', [FAICacheLoadCount]));
  // Debug: lista symbols no cache IA
  if FAICache.Count > 0 then
  begin
    var LCacheKeys := '';
    for var LKey in FAICache.Keys do
      LCacheKeys := LCacheKeys + LKey + ' ';
    AddLog('Sistema', 'Cache IA symbols: ' + LCacheKeys);
  end;

  // Envia config
  LCfg := TJSONObject.Create;
  LCfg.AddPair('apiKeyTest',    GetCfgStr('apiKeyTest', ''));
  LCfg.AddPair('secretKeyTest', GetCfgStr('secretKeyTest', ''));
  LCfg.AddPair('apiKeyProd',    GetCfgStr('apiKeyProd', ''));
  LCfg.AddPair('secretKeyProd', GetCfgStr('secretKeyProd', ''));
  LCfg.AddPair('testnet',      TJSONBool.Create(GetCfgBool('testnet', True)));
  LCfg.AddPair('aiKey',        GetCfgStr('aiKey', ''));
  LCfg.AddPair('aiModel',      GetCfgStr('aiModel', 'gpt-4o-mini'));
  LCfg.AddPair('aiVision',     TJSONBool.Create(GetCfgBool('aiVision', False)));
  LCfg.AddPair('aiBaseURL',    GetCfgStr('aiBaseURL', ''));
  LCfg.AddPair('aiCacheMins',  GetCfgStr('aiCacheMins', '15'));
  LCfg.AddPair('aiKeyOpenai',  GetCfgStr('aiKeyOpenai', ''));
  LCfg.AddPair('aiKeyGroq',    GetCfgStr('aiKeyGroq', ''));
  LCfg.AddPair('aiKeyMistral', GetCfgStr('aiKeyMistral', ''));
  LCfg.AddPair('aiKeyCerebras',GetCfgStr('aiKeyCerebras', ''));
  LCfg.AddPair('aiKeyDeepseek',GetCfgStr('aiKeyDeepseek', ''));
  LCfg.AddPair('tradeAmount',  GetCfgStr('tradeAmount', '100'));
  LCfg.AddPair('trailingStop',  GetCfgStr('trailingStop', '3.0'));
  LCfg.AddPair('takeProfit',   GetCfgStr('takeProfit', '8.0'));
  LCfg.AddPair('minConfidence',GetCfgStr('minConfidence', '70'));
  LCfg.AddPair('minScore',    GetCfgStr('minScore', '25'));
  LCfg.AddPair('botInterval',  GetCfgStr('botInterval', '180'));
  LCfg.AddPair('autoTrade',    TJSONBool.Create(GetCfgBool('autoTrade', False)));
  LCfg.AddPair('interval',     GetCfgStr('interval', '1h'));
  LCfg.AddPair('topCoins',       GetCfgStr('topCoins', '30'));
  LCfg.AddPair('scanMode',      GetCfgStr('scanMode', 'recovery'));
  LCfg.AddPair('recoveryHours', GetCfgStr('recoveryHours', '24'));
  LCfg.AddPair('lateralTimeout', GetCfgStr('lateralTimeout', '24'));
  LCfg.AddPair('dcaEnabled',   TJSONBool.Create(GetCfgBool('dcaEnabled', False)));
  LCfg.AddPair('dcaMax',       GetCfgStr('dcaMax', '3'));
  LCfg.AddPair('dcaLevel1',    GetCfgStr('dcaLevel1', '3'));
  LCfg.AddPair('dcaLevel2',    GetCfgStr('dcaLevel2', '5'));
  LCfg.AddPair('dcaLevel3',    GetCfgStr('dcaLevel3', '8'));
  LCfg.AddPair('tradeCooldown', GetCfgStr('tradeCooldown', '30'));
  LCfg.AddPair('snapshotInterval', GetCfgStr('snapshotInterval', '30'));
  LCfg.AddPair('telegramEnabled', TJSONBool.Create(GetCfgBool('telegramEnabled', False)));
  LCfg.AddPair('telegramToken',   GetCfgStr('telegramToken', ''));
  LCfg.AddPair('telegramChatId',  GetCfgStr('telegramChatId', ''));
  SendToJS('loadConfig', LCfg);

  // Carregar trades persistidos do banco
  var LTradesData: TJSONObject;
  var LTradesArr: TJSONArray;
  LTradesArr := FDB.LoadTrades;
  if LTradesArr.Count > 0 then
  begin
    LTradesData := TJSONObject.Create;
    LTradesData.AddPair('trades', LTradesArr);
    SendToJS('loadTrades', LTradesData);
    AddLog('Sistema', Format('Carregados %d trades do banco de dados.', [LTradesArr.Count]));
  end
  else
    LTradesArr.Free;

  LConn := TJSONObject.Create;
  LConn.AddPair('connected', TJSONBool.Create(False));
  LConn.AddPair('testnet', TJSONBool.Create(GetCfgBool('testnet', True)));
  SendToJS('connectionStatus', LConn);

  // Testa conexao automaticamente ao iniciar
  DoTestConnection;

  // Carregar snapshots da carteira e enviar ao JS
  var LSnapshotsArr: TJSONArray;
  LSnapshotsArr := FDB.LoadWalletSnapshots(500);
  if LSnapshotsArr.Count > 0 then
  begin
    var LSnapData := TJSONObject.Create;
    LSnapData.AddPair('snapshots', LSnapshotsArr);
    SendToJS('walletSnapshots', LSnapData);
    AddLog('Sistema', Format('Carregados %d snapshots da carteira.', [LSnapshotsArr.Count]));
  end
  else
    LSnapshotsArr.Free;

  // Configura intervalo do timer wallet (minutos -> ms)
  var LWalletMin := Trunc(GetCfgDbl('snapshotInterval', 30));
  if LWalletMin < 1 then LWalletMin := 30;
  FTimerWallet.Interval := LWalletMin * 60 * 1000;
  FTimerWallet.Enabled := True;

  // Inicia timers e primeiro scan
  FTimerPrice.Enabled := True;
  FTimerScan.Enabled := True;
  DoScan;

  // Auto-inicia o bot
  DoStartBot;
end;

{ ================================================================
  SCANNER - Top 10 Recovery Coins
  ================================================================ }

procedure TfrmMain.DoScan;
var
  D: TJSONObject;
begin
  if FScanning then
  begin
    AddLog('Scanner', 'Scan ja em andamento...');
    Exit;
  end;

  FScanning := True;
  D := TJSONObject.Create;
  D.AddPair('message', 'Escaneando mercado...');
  SendToJS('scanProgress', D);
  var LScanMode := GetCfgStr('scanMode', 'recovery');
  AddLog('Scanner', Format('Iniciando scan (modo: %s)...', [LScanMode]));

  var LTopCount := Trunc(GetCfgDbl('topCoins', 30));
  if LTopCount < 1 then LTopCount := 30;
  var LRecoveryHours := Trunc(GetCfgDbl('recoveryHours', 24));
  var LWindowSize := HoursToWindowSize(LRecoveryHours);
  var LInterval := GetInterval;

  TThread.CreateAnonymousThread(procedure
  var
    LTickers: TJSONArray;
    LList, LPreList: TList<TCoinRecovery>;
    I: Integer;
    LObj: TJSONObject;
    LCoin: TCoinRecovery;
    LSymbol: string;
    LChange, LVol: Double;
    LNeedIndicators: Boolean;
    LCandles: TCandleArray;
    LInd: TTechnicalIndicators;
    LTicker2: TJSONObject;
    LPrice24h, LVol24h: Double;
    LBBWidth, LPrevHist: Double;
  begin
    try
      LNeedIndicators := (LScanMode = 'rsi') or (LScanMode = 'breakout')
        or (LScanMode = 'macd') or (LScanMode = 'momentum')
        or (LScanMode = 'multi');

      // AI Select: busca lista curada da Binance, depois pega tickers individuais
      if LScanMode = 'aiselect' then
      begin
        var LAISymbols := FBinance.GetAISelectSymbols;
        if Length(LAISymbols) = 0 then
        begin
          TThread.Synchronize(nil, procedure
          begin
            AddLog('Erro', 'AI Select: nenhuma moeda retornada pela Binance');
            FScanning := False;
            var DEnd := TJSONObject.Create;
            DEnd.AddPair('message', '');
            SendToJS('scanProgress', DEnd);
          end);
          Exit;
        end;

        // Monta lista de coins a partir dos tickers 24h individuais
        var LAIList := TList<TCoinRecovery>.Create;
        try
          for var SI := 0 to High(LAISymbols) do
          begin
            var LProg := Format('AI Select %d/%d: %s', [SI + 1, Length(LAISymbols), LAISymbols[SI]]);
            TThread.Synchronize(nil, procedure
            begin
              var DP := TJSONObject.Create;
              DP.AddPair('message', LProg);
              SendToJS('scanProgress', DP);
            end);

            var LTk: TJSONObject := nil;
            try
              LTk := FBinance.Get24hTicker(LAISymbols[SI]);
            except end;
            if LTk = nil then Continue;
            try
              LCoin.Symbol := LAISymbols[SI];
              LCoin.Price := StrToFloatDef(LTk.GetValue<string>('lastPrice', '0'), 0, FmtDot);
              LCoin.PriceChangePercent := StrToFloatDef(LTk.GetValue<string>('priceChangePercent', '0'), 0, FmtDot);
              LCoin.Volume := StrToFloatDef(LTk.GetValue<string>('volume', '0'), 0, FmtDot);
              LCoin.HighPrice := StrToFloatDef(LTk.GetValue<string>('highPrice', '0'), 0, FmtDot);
              LCoin.LowPrice := StrToFloatDef(LTk.GetValue<string>('lowPrice', '0'), 0, FmtDot);
              LCoin.QuoteVolume := StrToFloatDef(LTk.GetValue<string>('quoteVolume', '0'), 0, FmtDot);
              LCoin.ScanMetric := LCoin.QuoteVolume;
              LAIList.Add(LCoin);
            finally
              LTk.Free;
            end;
            Sleep(50);
          end;

          // Mantem ordem original (rank do AI Select da Binance)
          FTopCoins := LAIList.ToArray;
        finally
          LAIList.Free;
        end;

        TThread.Synchronize(nil, procedure
        begin
          SendTopCoins;
          AddLog('Scanner', Format('Scan completo! %d moedas AI Select da Binance', [Length(FTopCoins)]));
          FScanning := False;
          var DEnd := TJSONObject.Create;
          DEnd.AddPair('message', '');
          SendToJS('scanProgress', DEnd);
          if (FSelectedSymbol = '') and (Length(FTopCoins) > 0) then
            DoSelectCoin(FTopCoins[0].Symbol);
        end);
        Exit;
      end;

      // Flash dip usa janela de 1h
      if LScanMode = 'flashdip' then
        LTickers := FBinance.GetAllTickersWindow('1h')
      else if (LScanMode = 'volume') or LNeedIndicators then
        LTickers := FBinance.GetAll24hTickers
      else
        LTickers := FBinance.GetAllTickersWindow(LWindowSize);

      if LTickers = nil then
      begin
        TThread.Synchronize(nil, procedure
        begin
          AddLog('Erro', 'Falha ao obter tickers');
          FScanning := False;
          var DEnd := TJSONObject.Create;
          DEnd.AddPair('message', '');
          SendToJS('scanProgress', DEnd);
        end);
        Exit;
      end;

      try
        LList := TList<TCoinRecovery>.Create;
        try
          // === PASSO 1: Montar lista base de pares USDT com volume ===
          LPreList := TList<TCoinRecovery>.Create;
          try
            for I := 0 to LTickers.Count - 1 do
            begin
              LObj := TJSONObject(LTickers.Items[I]);
              LSymbol := LObj.GetValue<string>('symbol', '');
              if not LSymbol.EndsWith('USDT') then Continue;
              LVol := StrToFloatDef(LObj.GetValue<string>('quoteVolume', '0'), 0, FmtDot);
              if LVol < 1000000 then Continue;

              LChange := StrToFloatDef(LObj.GetValue<string>('priceChangePercent', '0'), 0, FmtDot);

              LCoin.Symbol := LSymbol;
              LCoin.Price := StrToFloatDef(LObj.GetValue<string>('lastPrice', '0'), 0, FmtDot);
              LCoin.PriceChangePercent := LChange;
              LCoin.Volume := StrToFloatDef(LObj.GetValue<string>('volume', '0'), 0, FmtDot);
              LCoin.HighPrice := StrToFloatDef(LObj.GetValue<string>('highPrice', '0'), 0, FmtDot);
              LCoin.LowPrice := StrToFloatDef(LObj.GetValue<string>('lowPrice', '0'), 0, FmtDot);
              LCoin.QuoteVolume := LVol;
              LCoin.ScanMetric := 0;
              LPreList.Add(LCoin);
            end;

            // === PASSO 2: Filtro especifico por modo ===

            if LScanMode = 'recovery' then
            begin
              for I := 0 to LPreList.Count - 1 do
                if LPreList[I].PriceChangePercent > 0 then
                begin
                  LCoin := LPreList[I];
                  LCoin.ScanMetric := LCoin.PriceChangePercent;
                  LList.Add(LCoin);
                end;
            end

            else if LScanMode = 'volume' then
            begin
              for I := 0 to LPreList.Count - 1 do
              begin
                LCoin := LPreList[I];
                LCoin.ScanMetric := LCoin.QuoteVolume;
                LList.Add(LCoin);
              end;
            end

            else if LScanMode = 'flashdip' then
            begin
              // Moedas que cairam >5% na ultima hora com volume alto
              for I := 0 to LPreList.Count - 1 do
                if LPreList[I].PriceChangePercent <= -5 then
                begin
                  LCoin := LPreList[I];
                  LCoin.ScanMetric := LCoin.PriceChangePercent; // mais negativo = mais queda
                  LList.Add(LCoin);
                end;
            end

            // === MULTI-SCAN: roda todos os filtros e conta confluencias ===
            else if LScanMode = 'multi' then
            begin
              // Top 50 por volume para buscar klines
              LPreList.Sort(TComparer<TCoinRecovery>.Construct(
                function(const A, B: TCoinRecovery): Integer
                begin
                  if A.QuoteVolume > B.QuoteVolume then Result := -1
                  else if A.QuoteVolume < B.QuoteVolume then Result := 1
                  else Result := 0;
                end
              ));
              if LPreList.Count > 50 then
                LPreList.DeleteRange(50, LPreList.Count - 50);

              for I := 0 to LPreList.Count - 1 do
              begin
                if not FScanning then Break;
                LCoin := LPreList[I];
                var LConf: Integer := 0;
                var LTags: string := '';

                // Progress
                var LProg := Format('Multi-Scan %d/%d: %s', [I + 1, LPreList.Count, LCoin.Symbol]);
                TThread.Synchronize(nil, procedure
                begin
                  var DP := TJSONObject.Create;
                  DP.AddPair('message', LProg);
                  SendToJS('scanProgress', DP);
                end);

                // a) Recovery: variacao positiva 24h
                if LCoin.PriceChangePercent > 0 then
                begin Inc(LConf); LTags := LTags + 'Recovery '; end;

                // b) Volume: top 30 por volume (ja estamos no top 50)
                if I < 30 then
                begin Inc(LConf); LTags := LTags + 'Volume '; end;

                // Busca klines para indicadores
                try
                  LCandles := FBinance.GetKlines(LCoin.Symbol, LInterval, 60);
                except
                  LCandles := nil;
                end;

                if (LCandles <> nil) and (Length(LCandles) >= 20) then
                begin
                  LPrice24h := 0; LVol24h := 0;
                  try
                    LTicker2 := FBinance.Get24hTicker(LCoin.Symbol);
                    try
                      if LTicker2 <> nil then
                      begin
                        LPrice24h := StrToFloatDef(LTicker2.GetValue<string>('prevClosePrice', '0'), 0, FmtDot);
                        LVol24h := StrToFloatDef(LTicker2.GetValue<string>('quoteVolume', '0'), 0, FmtDot);
                      end;
                    finally
                      LTicker2.Free;
                    end;
                  except end;

                  LInd := TTechnicalAnalysis.FullAnalysis(LCandles, LPrice24h, LVol24h);
                  LCoin.Price := LInd.CurrentPrice;

                  // c) RSI extremo
                  if (LInd.RSI < 30) or (LInd.RSI > 70) then
                  begin Inc(LConf); LTags := LTags + 'RSI '; end;

                  // d) Breakout (Bollinger squeeze)
                  if (LInd.BollingerMiddle > 0) and (LInd.BollingerUpper > LInd.BollingerLower) then
                  begin
                    LBBWidth := (LInd.BollingerUpper - LInd.BollingerLower) / LInd.BollingerMiddle * 100;
                    if (LBBWidth < 4) and
                       ((LInd.CurrentPrice > LInd.BollingerUpper) or (LInd.CurrentPrice < LInd.BollingerLower)) then
                    begin Inc(LConf); LTags := LTags + 'Breakout '; end;
                  end;

                  // e) MACD crossover
                  if Length(LCandles) >= 3 then
                  begin
                    LPrevHist := LCandles[High(LCandles)-1].Close - LCandles[High(LCandles)-2].Close;
                    if ((LInd.MACDHistogram > 0) and (LPrevHist <= 0)) or
                       ((LInd.MACDHistogram < 0) and (LPrevHist >= 0)) then
                    begin Inc(LConf); LTags := LTags + 'MACD '; end;
                  end;

                  // f) Momentum forte
                  var LMomScore: Double := 0;
                  if LInd.SMA20 > LInd.SMA50 then LMomScore := LMomScore + 25 else LMomScore := LMomScore - 25;
                  if (LInd.RSI >= 50) and (LInd.RSI <= 70) then LMomScore := LMomScore + 20
                  else if (LInd.RSI >= 30) and (LInd.RSI < 50) then LMomScore := LMomScore - 20;
                  if LInd.MACDHistogram > 0 then LMomScore := LMomScore + 25 else LMomScore := LMomScore - 25;
                  if LInd.CurrentPrice > LInd.SMA20 then LMomScore := LMomScore + 15 else LMomScore := LMomScore - 15;
                  if LInd.EMA12 > LInd.EMA26 then LMomScore := LMomScore + 15 else LMomScore := LMomScore - 15;
                  if Abs(LMomScore) >= 50 then
                  begin Inc(LConf); LTags := LTags + 'Momentum '; end;
                end;

                // Adiciona se tem pelo menos 1 confluencia
                if LConf > 0 then
                begin
                  // ScanMetric = confluencias + fracao do volume para desempate
                  LCoin.ScanMetric := LConf + (LCoin.QuoteVolume / 1e12);
                  LList.Add(LCoin);

                  var LLogConf := Format('[Multi] %s: %d/6 confluencias [%s]',
                    [LCoin.Symbol, LConf, Trim(LTags)]);
                  TThread.Synchronize(nil, procedure begin AddLog('Scanner', LLogConf); end);
                end;

                Sleep(100);
              end; // for multi
            end

            else if LNeedIndicators then
            begin
              // Modos que precisam de indicadores: pre-filtrar por volume, top 50
              LPreList.Sort(TComparer<TCoinRecovery>.Construct(
                function(const A, B: TCoinRecovery): Integer
                begin
                  if A.QuoteVolume > B.QuoteVolume then Result := -1
                  else if A.QuoteVolume < B.QuoteVolume then Result := 1
                  else Result := 0;
                end
              ));
              if LPreList.Count > 50 then
                LPreList.DeleteRange(50, LPreList.Count - 50);

              for I := 0 to LPreList.Count - 1 do
              begin
                if not FScanning then Break; // Cancelado?
                LCoin := LPreList[I];

                // Progress
                var LProg := Format('Analisando %d/%d: %s', [I + 1, LPreList.Count, LCoin.Symbol]);
                TThread.Synchronize(nil, procedure
                begin
                  var DP := TJSONObject.Create;
                  DP.AddPair('message', LProg);
                  SendToJS('scanProgress', DP);
                end);

                // Busca klines
                try
                  LCandles := FBinance.GetKlines(LCoin.Symbol, LInterval, 60);
                except
                  Continue;
                end;
                if Length(LCandles) < 20 then Continue;

                // Calcula indicadores
                LPrice24h := 0; LVol24h := 0;
                try
                  LTicker2 := FBinance.Get24hTicker(LCoin.Symbol);
                  try
                    if LTicker2 <> nil then
                    begin
                      LPrice24h := StrToFloatDef(LTicker2.GetValue<string>('prevClosePrice', '0'), 0, FmtDot);
                      LVol24h := StrToFloatDef(LTicker2.GetValue<string>('quoteVolume', '0'), 0, FmtDot);
                    end;
                  finally
                    LTicker2.Free;
                  end;
                except end;

                LInd := TTechnicalAnalysis.FullAnalysis(LCandles, LPrice24h, LVol24h);

                // --- RSI Extremos ---
                if LScanMode = 'rsi' then
                begin
                  if (LInd.RSI < 30) or (LInd.RSI > 70) then
                  begin
                    LCoin.ScanMetric := Abs(LInd.RSI - 50); // mais extremo = melhor
                    LCoin.Price := LInd.CurrentPrice;
                    LList.Add(LCoin);
                  end;
                end

                // --- Breakout (Bollinger Squeeze) ---
                else if LScanMode = 'breakout' then
                begin
                  if (LInd.BollingerMiddle > 0) and (LInd.BollingerUpper > LInd.BollingerLower) then
                  begin
                    LBBWidth := (LInd.BollingerUpper - LInd.BollingerLower) / LInd.BollingerMiddle * 100;
                    // Banda estreita (< 4%) e preco rompendo
                    if (LBBWidth < 4) and
                       ((LInd.CurrentPrice > LInd.BollingerUpper) or (LInd.CurrentPrice < LInd.BollingerLower)) then
                    begin
                      LCoin.ScanMetric := 4 - LBBWidth; // mais apertado = melhor
                      LCoin.Price := LInd.CurrentPrice;
                      LList.Add(LCoin);
                    end;
                  end;
                end

                // --- MACD Crossover ---
                else if LScanMode = 'macd' then
                begin
                  // Verifica cruzamento recente: MACD cruzou signal
                  // Histograma mudou de sinal nas ultimas velas = cruzamento fresco
                  if Length(LCandles) >= 3 then
                  begin
                    // Histograma atual vs anterior (simplificado)
                    LPrevHist := LCandles[High(LCandles)-1].Close - LCandles[High(LCandles)-2].Close;
                    if ((LInd.MACDHistogram > 0) and (LPrevHist <= 0)) or
                       ((LInd.MACDHistogram < 0) and (LPrevHist >= 0)) then
                    begin
                      // Cruzamento detectado! Metrica = forca do histograma
                      LCoin.ScanMetric := Abs(LInd.MACDHistogram) * 1000;
                      LCoin.Price := LInd.CurrentPrice;
                      LList.Add(LCoin);
                    end
                    else if Abs(LInd.MACDHistogram) > 0 then
                    begin
                      // Mesmo sem cruzamento, MACD forte conta
                      LCoin.ScanMetric := Abs(LInd.MACDHistogram) * 500;
                      LCoin.Price := LInd.CurrentPrice;
                      if LCoin.ScanMetric > 0.1 then
                        LList.Add(LCoin);
                    end;
                  end;
                end

                // --- Momentum (Tendencia Forte) ---
                else if LScanMode = 'momentum' then
                begin
                  var LMomScore: Double := 0;
                  // SMA20 > SMA50 = tendencia de alta (+25)
                  if LInd.SMA20 > LInd.SMA50 then LMomScore := LMomScore + 25
                  else LMomScore := LMomScore - 25;
                  // RSI 50-70 = forca sem sobrecompra (+20)
                  if (LInd.RSI >= 50) and (LInd.RSI <= 70) then LMomScore := LMomScore + 20
                  else if (LInd.RSI >= 30) and (LInd.RSI < 50) then LMomScore := LMomScore - 20;
                  // MACD positivo e crescente (+25)
                  if LInd.MACDHistogram > 0 then LMomScore := LMomScore + 25
                  else LMomScore := LMomScore - 25;
                  // Preco acima de SMA20 (+15)
                  if LInd.CurrentPrice > LInd.SMA20 then LMomScore := LMomScore + 15
                  else LMomScore := LMomScore - 15;
                  // EMA12 > EMA26 (+15)
                  if LInd.EMA12 > LInd.EMA26 then LMomScore := LMomScore + 15
                  else LMomScore := LMomScore - 15;

                  if Abs(LMomScore) >= 50 then // So moedas com momentum forte
                  begin
                    LCoin.ScanMetric := LMomScore;
                    LCoin.Price := LInd.CurrentPrice;
                    LList.Add(LCoin);
                  end;
                end;

                Sleep(100); // Rate limit
              end; // for
            end; // needIndicators

          finally
            LPreList.Free;
          end;

          // === PASSO 3: Ordenacao ===
          if LScanMode = 'flashdip' then
          begin
            // Maior queda primeiro (mais negativo primeiro)
            LList.Sort(TComparer<TCoinRecovery>.Construct(
              function(const A, B: TCoinRecovery): Integer
              begin
                if A.ScanMetric < B.ScanMetric then Result := -1
                else if A.ScanMetric > B.ScanMetric then Result := 1
                else Result := 0;
              end
            ));
          end
          else
          begin
            // Maior metrica primeiro (para todos os outros modos)
            LList.Sort(TComparer<TCoinRecovery>.Construct(
              function(const A, B: TCoinRecovery): Integer
              begin
                if A.ScanMetric > B.ScanMetric then Result := -1
                else if A.ScanMetric < B.ScanMetric then Result := 1
                else Result := 0;
              end
            ));
          end;

          // Pega top N
          if LList.Count > LTopCount then
            LList.DeleteRange(LTopCount, LList.Count - LTopCount);

          FTopCoins := LList.ToArray;
        finally
          LList.Free;
        end;
      finally
        LTickers.Free;
      end;

      TThread.Synchronize(nil, procedure
      begin
        SendTopCoins;
        AddLog('Scanner', Format('Scan completo! %d moedas encontradas (modo: %s)', [Length(FTopCoins), LScanMode]));
        FScanning := False;
        var DEnd := TJSONObject.Create;
        DEnd.AddPair('message', '');
        SendToJS('scanProgress', DEnd);

        if (FSelectedSymbol = '') and (Length(FTopCoins) > 0) then
          DoSelectCoin(FTopCoins[0].Symbol);
      end);
    except
      on E: Exception do
        TThread.Synchronize(nil, procedure
        begin
          AddLog('Erro', 'Scan: ' + E.Message);
          FScanning := False;
          var DEnd := TJSONObject.Create;
          DEnd.AddPair('message', '');
          SendToJS('scanProgress', DEnd);
        end);
    end;
  end).Start;
end;

procedure TfrmMain.SendTopCoins;
var
  D: TJSONObject;
  A: TJSONArray;
  I: Integer;
  C: TJSONObject;
  LCached: TAIAnalysis;
begin
  D := TJSONObject.Create;
  A := TJSONArray.Create;
  for I := 0 to High(FTopCoins) do
  begin
    C := TJSONObject.Create;
    C.AddPair('symbol', FTopCoins[I].Symbol);
    C.AddPair('price', TJSONNumber.Create(FTopCoins[I].Price));
    C.AddPair('changePercent', TJSONNumber.Create(FTopCoins[I].PriceChangePercent));
    C.AddPair('volume', TJSONNumber.Create(FTopCoins[I].Volume));
    C.AddPair('high', TJSONNumber.Create(FTopCoins[I].HighPrice));
    C.AddPair('low', TJSONNumber.Create(FTopCoins[I].LowPrice));
    C.AddPair('quoteVolume', TJSONNumber.Create(FTopCoins[I].QuoteVolume));
    C.AddPair('scanMetric', TJSONNumber.Create(FTopCoins[I].ScanMetric));
    if FAICache.TryGetValue(FTopCoins[I].Symbol, LCached) then
      C.AddPair('aiConfidence', TJSONNumber.Create(LCached.Confidence))
    else
      C.AddPair('aiConfidence', TJSONNumber.Create(-1));
    A.AddElement(C);
  end;
  D.AddPair('coins', A);
  SendToJS('topCoins', D);
end;

{ ================================================================
  SELECT COIN
  ================================================================ }

procedure TfrmMain.DoSelectCoin(const Symbol: string);
var
  D: TJSONObject;
  LInterval: string;
  LCachedAnalysis: TAIAnalysis;
  LHasCached: Boolean;
begin
  if Symbol = '' then Exit;
  FSelectedSymbol := Symbol;
  FLastAutoTradeSignal := tsHold;  // Reset ao trocar de moeda
  AddLog('Scanner', 'Moeda selecionada: ' + Symbol);

  D := TJSONObject.Create;
  D.AddPair('symbol', Symbol);
  SendToJS('selectedCoin', D);

  // Verifica se ha analise IA em cache para mostrar imediatamente
  LHasCached := FAICache.TryGetValue(Symbol, LCachedAnalysis);

  LInterval := GetInterval;

  // Carrega candles, indicadores e grafico em background (rapido, sem IA)
  TThread.CreateAnonymousThread(procedure
  var
    LCandles: TCandleArray;
    LIndicators: TTechnicalIndicators;
    LTicker: TJSONObject;
    LPrice24hAgo, LVol24h: Double;
  begin
    try
      LCandles := FBinance.GetKlines(Symbol, LInterval, 100);
      if Length(LCandles) = 0 then
      begin
        TThread.Queue(nil, procedure
        begin
          AddLog('Erro', 'Nenhum candle para ' + Symbol);
        end);
        Exit;
      end;
      FLastCandles := LCandles;

      LPrice24hAgo := 0; LVol24h := 0;
      LTicker := FBinance.Get24hTicker(Symbol);
      try
        if LTicker <> nil then
        begin
          LPrice24hAgo := StrToFloatDef(LTicker.GetValue<string>('prevClosePrice', '0'), 0, FmtDot);
          LVol24h := StrToFloatDef(LTicker.GetValue<string>('quoteVolume', '0'), 0, FmtDot);
        end;
      finally
        LTicker.Free;
      end;

      LIndicators := TTechnicalAnalysis.FullAnalysis(LCandles, LPrice24hAgo, LVol24h);
      FLastIndicators := LIndicators;

      TThread.Queue(nil, procedure
      begin
        SendCandles;
        SendIndicators;
        UpdatePrice;
        // Mostra ultimo sinal IA do cache (se houver)
        if LHasCached then
        begin
          FLastAnalysis := LCachedAnalysis;
          SendSignal;
        end;
      end);
    except
      on E: Exception do
      begin
        var LErr := Symbol + ': ' + E.Message;
        TThread.Queue(nil, procedure
        begin
          AddLog('Erro', LErr);
        end);
      end;
    end;
  end).Start;
end;

{ ================================================================
  ANALYSIS (AI)
  ================================================================ }

procedure TfrmMain.DoAnalyze;
var
  D: TJSONObject;
begin
  if FSelectedSymbol = '' then
  begin
    AddLog('Bot', 'Selecione uma moeda primeiro!');
    Exit;
  end;

  if FAnalyzing then
  begin
    AddLog('Bot', 'Analise ja em andamento...');
    Exit;
  end;

  FAnalyzing := True;
  D := TJSONObject.Create;
  D.AddPair('active', TJSONBool.Create(True));
  SendToJS('analyzing', D);
  AddLog('Bot', 'Analisando ' + FSelectedSymbol + '...');

  TThread.CreateAnonymousThread(procedure
  var
    LCandles: TCandleArray;
    LIndicators: TTechnicalIndicators;
    LAnalysis: TAIAnalysis;
    LTicker: TJSONObject;
    LPrice24hAgo, LVol24h, LScore: Double;
    LSymbol: string;
  begin
    LSymbol := FSelectedSymbol;
    try
      LCandles := FBinance.GetKlines(LSymbol, GetInterval, 100);
      if Length(LCandles) = 0 then
      begin
        TThread.Queue(nil, procedure
        var DA: TJSONObject;
        begin
          AddLog('Erro', 'Nenhum candle retornado');
          FAnalyzing := False;
          DA := TJSONObject.Create;
          DA.AddPair('active', TJSONBool.Create(False));
          SendToJS('analyzing', DA);
        end);
        Exit;
      end;
      FLastCandles := LCandles;

      LPrice24hAgo := 0; LVol24h := 0;
      LTicker := FBinance.Get24hTicker(LSymbol);
      try
        if LTicker <> nil then
        begin
          LPrice24hAgo := StrToFloatDef(LTicker.GetValue<string>('prevClosePrice', '0'), 0, FmtDot);
          LVol24h := StrToFloatDef(LTicker.GetValue<string>('quoteVolume', '0'), 0, FmtDot);
        end;
      finally
        LTicker.Free;
      end;

      LIndicators := TTechnicalAnalysis.FullAnalysis(LCandles, LPrice24hAgo, LVol24h);
      FLastIndicators := LIndicators;

      TThread.Queue(nil, procedure
      begin
        SendCandles;
        SendIndicators;
        AddLog('Bot', 'Indicadores calculados para ' + LSymbol);
      end);

      // Verifica posicao aberta para contexto da IA (media ponderada DCA)
      var LHasPos: Boolean := False;
      var LBuyPrice: Double := 0;
      var LPosTotQty: Double := 0;
      var LPosTotCost: Double := 0;
      for var PIdx := 0 to FOpenPositions.Count - 1 do
        if FOpenPositions[PIdx].Symbol = LSymbol then
        begin
          LHasPos := True;
          LPosTotQty := LPosTotQty + FOpenPositions[PIdx].Quantity;
          LPosTotCost := LPosTotCost + (FOpenPositions[PIdx].BuyPrice * FOpenPositions[PIdx].Quantity);
        end;
      if LHasPos and (LPosTotQty > 0) then
        LBuyPrice := LPosTotCost / LPosTotQty;

      // IA ou score tecnico
      if GetCfgStr('aiKey', '') <> '' then
      begin
        var LMSW := TStopwatch.StartNew;
        try
          LAnalysis := FAIEngine.AnalyzeMarket(LSymbol, LIndicators, LCandles, LHasPos, LBuyPrice);
        except
          on E: Exception do
          begin
            LAnalysis.Signal := tsHold;
            LAnalysis.Confidence := 0;
            LAnalysis.Reasoning := 'Erro IA: ' + E.Message;
            LAnalysis.Timestamp := Now;
          end;
        end;
        LMSW.Stop;
        var LMTkIn := FAIEngine.LastPromptTokens;
        var LMTkOut := FAIEngine.LastCompletionTokens;
        var LMElapsed := LMSW.ElapsedMilliseconds;
        TThread.Queue(nil, procedure
        begin
          Inc(FAITotalCalls);
          Inc(FAITotalTokensIn, LMTkIn);
          Inc(FAITotalTokensOut, LMTkOut);
          Inc(FAITotalTimeMs, LMElapsed);
          SendAIStats;
        end);
      end
      else
      begin
        var LBreakdown: string;
        LScore := TTechnicalAnalysis.TechnicalScoreEx(LIndicators, LBreakdown);
        LAnalysis.Signal := tsHold;
        LAnalysis.Confidence := Abs(LScore);
        if LScore > 60 then LAnalysis.Signal := tsStrongBuy
        else if LScore > 40 then LAnalysis.Signal := tsBuy
        else if LScore < -60 then LAnalysis.Signal := tsStrongSell
        else if LScore < -40 then LAnalysis.Signal := tsSell;
        LAnalysis.Reasoning := LBreakdown;
        LAnalysis.Timestamp := Now;
        LAnalysis.SuggestedEntry := LIndicators.CurrentPrice;
        LAnalysis.SuggestedStopLoss := LIndicators.CurrentPrice * (1 - GetCfgDbl('trailingStop', 3) / 100);
        LAnalysis.SuggestedTakeProfit := LIndicators.CurrentPrice * (1 + GetCfgDbl('takeProfit', 8) / 100);
      end;
      FLastAnalysis := LAnalysis;

      TThread.Queue(nil, procedure
      var DA: TJSONObject; LAmt: Double;
      begin
        SendSignal;
        AddLog('Bot', Format('%s -> Sinal: %s | Confianca: %.0f%%',
          [LSymbol, SignalToStr(LAnalysis.Signal), LAnalysis.Confidence]));
        AddLog('Bot', 'Motivo: ' + LAnalysis.Reasoning);

        // Salva no cache e no banco
        FAICache.AddOrSetValue(LSymbol, LAnalysis);
        try
          FDB.SaveAIAnalysis(LSymbol, LAnalysis);
        except
          on E: Exception do
            AddLog('Erro', 'SaveAIAnalysis(' + LSymbol + '): ' + E.Message);
        end;

        // Auto-trade (verifica posicoes reais, cooldown e confianca)
        if GetCfgBool('autoTrade', False) and FBotRunning then
        begin
          if LAnalysis.Confidence >= GetCfgDbl('minConfidence', 70) then
          begin
            // Verifica blacklist (vendido por lateralizacao)
            var LBlacklistTime: TDateTime;
            if FLateralBlacklist.TryGetValue(LSymbol, LBlacklistTime) then
            begin
              AddLog('Bot', Format('%s: BLOQUEADO (vendido por lateralizacao)', [LSymbol]));
            end
            else
            begin
            // Verifica cooldown entre trades no mesmo symbol
            var LCooldownMin: Double := GetCfgDbl('tradeCooldown', 30);
            var LLastTime: TDateTime;
            var LInCooldown: Boolean := False;
            if FLastTradeTime.TryGetValue(LSymbol, LLastTime) then
            begin
              var LElapsedMin: Double := MinutesBetween(Now, LLastTime) + (SecondsBetween(Now, LLastTime) mod 60) / 60.0;
              if LElapsedMin < LCooldownMin then
              begin
                LInCooldown := True;
                AddLog('Bot', Format('%s: Cooldown ativo (%.0f/%.0f min)',
                  [LSymbol, LElapsedMin, LCooldownMin]));
              end;
            end;

            if not LInCooldown then
            begin
              // Verifica se ja tem posicao aberta REAL para este symbol
              var LHasPosition: Boolean := False;
              for var PI := 0 to FOpenPositions.Count - 1 do
                if FOpenPositions[PI].Symbol = LSymbol then
                begin LHasPosition := True; Break; end;

              if (LAnalysis.Signal in [tsStrongBuy, tsBuy]) and LHasPosition then
              begin
                AddLog('Bot', LSymbol + ': Ja possui posicao aberta, aguardando sinal de venda');
              end
              else if (LAnalysis.Signal in [tsStrongSell, tsSell]) and not LHasPosition then
              begin
                AddLog('Bot', LSymbol + ': Sem posicao aberta para vender');
              end
              else
              begin
                LAmt := GetCfgDbl('tradeAmount', 100);
                case LAnalysis.Signal of
                  tsStrongBuy, tsBuy:
                  begin
                    AddLog('Trade', Format('AUTO-COMPRA %s | Motivo: %s', [LSymbol, LAnalysis.Reasoning]));
                    DoBuy(LAmt);
                    FLastTradeTime.AddOrSetValue(LSymbol, Now);
                  end;
                  tsStrongSell, tsSell:
                  begin
                    AddLog('Trade', Format('AUTO-VENDA %s | Motivo: %s', [LSymbol, LAnalysis.Reasoning]));
                    DoSell(LAmt);
                    FLastTradeTime.AddOrSetValue(LSymbol, Now);
                  end;
                else
                  AddLog('Bot', LSymbol + ': HOLD - sem sinal claro');
                end;
              end;
            end;
            end; // end blacklist else
          end
          else
            AddLog('Bot', Format('%s: Confianca %.0f%% < min %.0f%% - sem trade',
              [LSymbol, LAnalysis.Confidence, GetCfgDbl('minConfidence', 70)]));
        end;

        FAnalyzing := False;
        DA := TJSONObject.Create;
        DA.AddPair('active', TJSONBool.Create(False));
        SendToJS('analyzing', DA);
      end);
    except
      on E: Exception do
      begin
        var LErr := E.Message; // Capture before E is destroyed
        TThread.Queue(nil, procedure
        var DA: TJSONObject;
        begin
          AddLog('Erro', LErr);
          FAnalyzing := False;
          DA := TJSONObject.Create;
          DA.AddPair('active', TJSONBool.Create(False));
          SendToJS('analyzing', DA);
        end);
      end;
    end;
  end).Start;
end;

{ ================================================================
  TRADING
  ================================================================ }

procedure TfrmMain.DoBuy(Amount: Double);
var
  LQty: Double;
  LSymbol: string;
begin
  AddLog('Trade', Format('Compra solicitada: %.2f USDT', [Amount], FmtDot));
  LSymbol := FSelectedSymbol;
  if LSymbol = '' then begin AddLog('Erro', 'Selecione uma moeda primeiro'); Exit; end;
  if not FApiKeyValid then begin AddLog('Erro', 'API Key nao validada! Clique em "Testar Conexao" primeiro.'); Exit; end;
  if Amount < 6 then begin AddLog('Erro', Format('Valor minimo de compra: $6.00 (solicitado: $%.2f)', [Amount], FmtDot)); Exit; end;
  if FLastIndicators.CurrentPrice <= 0 then begin AddLog('Erro', 'Preco atual nao disponivel, aguarde carregamento'); Exit; end;

  LQty := Amount / FLastIndicators.CurrentPrice;
  AddLog('Trade', Format('Enviando COMPRA %s: ~%.8f @ $%.4f (quoteOrderQty=%.2f USDT)...',
    [LSymbol, LQty, FLastIndicators.CurrentPrice, Amount]));

  TThread.CreateAnonymousThread(procedure
  var LRes: TOrderResult;
  begin
    try
      // Price=Amount passa o valor em USDT para quoteOrderQty (BUY MARKET)
      LRes := FBinance.PlaceOrder(LSymbol, osBuy, otMarket, LQty, Amount);
      TThread.Queue(nil, procedure
      var DT: TJSONObject;
      begin
        if LRes.Success then begin
          AddLog('Trade', Format('OK! OrderID=%d | Preco exec: $%.4f | Qtd exec: %.8f',
            [LRes.OrderId, LRes.Price, LRes.Quantity], FmtDot));
          DT := TJSONObject.Create;
          DT.AddPair('timestamp', FormatDateTime('dd/mm/yyyy hh:nn:ss', Now));
          DT.AddPair('symbol', LSymbol);
          DT.AddPair('side', 'BUY');
          DT.AddPair('price', TJSONNumber.Create(LRes.Price));
          DT.AddPair('quantity', TJSONNumber.Create(LRes.Quantity));
          DT.AddPair('signal', SignalToStrEN(FLastAnalysis.Signal));
          DT.AddPair('confidence', TJSONNumber.Create(FLastAnalysis.Confidence));
          DT.AddPair('orderId', TJSONNumber.Create(LRes.OrderId));
          SendToJS('addTrade', DT);
          // Rastrear posicao aberta com preco REAL de execucao
          var LPos: TOpenPosition;
          LPos.Symbol := LSymbol;
          LPos.BuyPrice := LRes.Price;
          LPos.BuyTime := Now;
          LPos.Quantity := LRes.Quantity;
          LPos.HighestPrice := LRes.Price;
          FOpenPositions.Add(LPos);
          // Rastrear primeira entrada (nao reseta em recompras)
          if not FSymbolFirstEntry.ContainsKey(LSymbol) then
            FSymbolFirstEntry.AddOrSetValue(LSymbol, Now);
          // Persistir no banco
          FDB.SaveTrade(LSymbol, 'BUY', LRes.Price, LRes.Quantity,
            SignalToStrEN(FLastAnalysis.Signal), FLastAnalysis.Confidence, LRes.OrderId, Now);
          FDB.SavePosition(LSymbol, LRes.Price, Now, LRes.Quantity);
          AddLog('Posicao', Format('Aberta: %s | Preco: $%.4f | Qtd: %.8f',
            [LSymbol, LPos.BuyPrice, LPos.Quantity], FmtDot));
          SendTelegram(Format(
            '&#x1F7E2; <b>COMPRA</b> %s'#10 +
            'Preco: $%s'#10 +
            'Qtd: %s'#10 +
            'Total: $%s',
            [LSymbol,
             FormatFloat('0.########', LRes.Price, FmtDot),
             FormatFloat('0.########', LRes.Quantity, FmtDot),
             FormatFloat('0.00', LRes.Price * LRes.Quantity, FmtDot)]));
          UpdateBalance;
        end else
        begin
          AddLog('Erro', 'COMPRA falhou: ' + LRes.ErrorMsg);
          var DE := TJSONObject.Create;
          DE.AddPair('message', 'COMPRA ' + LSymbol + ' falhou: ' + LRes.ErrorMsg);
          SendToJS('tradeError', DE);
        end;
      end);
    except
      on E: Exception do
      begin
        var LErr := 'Excecao na COMPRA ' + LSymbol + ': ' + E.Message;
        TThread.Queue(nil, procedure
        begin
          AddLog('Erro', LErr);
          var DE := TJSONObject.Create;
          DE.AddPair('message', LErr);
          SendToJS('tradeError', DE);
        end);
      end;
    end;
  end).Start;
end;

procedure TfrmMain.DoSell(Amount: Double);
var
  LSymbol, LAsset: string;
  LDesiredQty, LPrice: Double;
begin
  LSymbol := FSelectedSymbol;
  if LSymbol = '' then begin AddLog('Erro', 'Selecione uma moeda primeiro'); Exit; end;
  if not FApiKeyValid then begin AddLog('Erro', 'API Key nao validada! Clique em "Testar Conexao" primeiro.'); Exit; end;

  // Guard: impede vendas duplicadas do mesmo symbol
  if FSellingSymbols.ContainsKey(LSymbol) then
  begin
    AddLog('Bot', Format('%s: Venda ja em andamento - ignorando', [LSymbol]));
    Exit;
  end;
  FSellingSymbols.AddOrSetValue(LSymbol, True);

  LPrice := FLastIndicators.CurrentPrice;
  if LPrice <= 0 then begin FSellingSymbols.Remove(LSymbol); AddLog('Erro', 'Preco atual nao disponivel, aguarde carregamento'); Exit; end;

  // Calcula quantidade desejada a vender
  if Amount > 0 then
    LDesiredQty := Amount / LPrice
  else
  begin
    // Amount=0: vende todas as posicoes rastreadas
    LDesiredQty := 0;
    for var PI := 0 to FOpenPositions.Count - 1 do
      if FOpenPositions[PI].Symbol = LSymbol then
        LDesiredQty := LDesiredQty + FOpenPositions[PI].Quantity;
  end;

  if (LDesiredQty * LPrice) < 0.10 then
  begin
    FSellingSymbols.Remove(LSymbol);
    AddLog('Erro', Format('Valor de venda muito pequeno ($%.4f < $0.10)', [LDesiredQty * LPrice]));
    Exit;
  end;

  // Extrai o asset do symbol (ex: RPLUSDT -> RPL)
  LAsset := LSymbol;
  if LAsset.EndsWith('USDT') then
    LAsset := Copy(LAsset, 1, Length(LAsset) - 4);

  AddLog('Trade', Format('Venda solicitada: %.2f USDT (%s: %.8f)', [Amount, LSymbol, LDesiredQty], FmtDot));

  // Consulta saldo e executa ordem em background (nao bloqueia a UI)
  TThread.CreateAnonymousThread(procedure
  var LRes: TOrderResult;
    LBal: TAssetBalance;
    LQty: Double;
  begin
    try
      // Consulta saldo REAL na Binance
      LBal := FBinance.GetBalance(LAsset);

      if LBal.Free <= 0 then
      begin
        TThread.Queue(nil, procedure
        begin
          FSellingSymbols.Remove(LSymbol);
          AddLog('Erro', Format('Sem saldo de %s na Binance (free=%.8f)', [LAsset, LBal.Free]));
          for var PI := FOpenPositions.Count - 1 downto 0 do
            if FOpenPositions[PI].Symbol = LSymbol then
              FOpenPositions.Delete(PI);
          FDB.DeleteAllPositions(LSymbol);
          AddLog('Bot', 'Posicoes locais removidas (sem saldo real): ' + LSymbol);
        end);
        Exit;
      end;

      // Usa o menor entre: quantidade desejada e saldo real (margem 0.1% para taxa)
      LQty := LBal.Free * 0.999;
      if (LDesiredQty > 0) and (LDesiredQty < LQty) then
        LQty := LDesiredQty;

      LRes := FBinance.PlaceOrder(LSymbol, osSell, otMarket, LQty);
      TThread.Queue(nil, procedure
      var DT: TJSONObject;
      begin
        FSellingSymbols.Remove(LSymbol);
        if LRes.Success then begin
          AddLog('Trade', Format('OK! OrderID=%d | Preco exec: $%.4f | Qtd exec: %.8f',
            [LRes.OrderId, LRes.Price, LRes.Quantity], FmtDot));
          DT := TJSONObject.Create;
          DT.AddPair('timestamp', FormatDateTime('dd/mm/yyyy hh:nn:ss', Now));
          DT.AddPair('symbol', LSymbol);
          DT.AddPair('side', 'SELL');
          DT.AddPair('price', TJSONNumber.Create(LRes.Price));
          DT.AddPair('quantity', TJSONNumber.Create(LRes.Quantity));
          DT.AddPair('signal', SignalToStrEN(FLastAnalysis.Signal));
          DT.AddPair('confidence', TJSONNumber.Create(FLastAnalysis.Confidence));
          DT.AddPair('orderId', TJSONNumber.Create(LRes.OrderId));
          SendToJS('addTrade', DT);
          // Persistir no banco
          FDB.SaveTrade(LSymbol, 'SELL', LRes.Price, LRes.Quantity,
            SignalToStrEN(FLastAnalysis.Signal), FLastAnalysis.Confidence, LRes.OrderId, Now);
          FDB.DeleteAllPositions(LSymbol);
          // Remover TODAS as posicoes do symbol vendido (DCA pode ter varias)
          for var PI := FOpenPositions.Count - 1 downto 0 do
            if FOpenPositions[PI].Symbol = LSymbol then
              FOpenPositions.Delete(PI);
          // Limpa rastreamento de primeira entrada (permite recompra futura)
          FSymbolFirstEntry.Remove(LSymbol);
          SendTelegram(Format(
            '&#x1F534; <b>VENDA</b> %s'#10 +
            'Preco: $%s'#10 +
            'Qtd: %s'#10 +
            'Total: $%s',
            [LSymbol,
             FormatFloat('0.########', LRes.Price, FmtDot),
             FormatFloat('0.########', LRes.Quantity, FmtDot),
             FormatFloat('0.00', LRes.Price * LRes.Quantity, FmtDot)]));
          UpdateBalance;
        end else
        begin
          AddLog('Erro', 'VENDA falhou: ' + LRes.ErrorMsg);
          var DE := TJSONObject.Create;
          DE.AddPair('message', 'VENDA ' + LSymbol + ' falhou: ' + LRes.ErrorMsg);
          SendToJS('tradeError', DE);
        end;
      end);
    except
      on E: Exception do
      begin
        var LErr := 'Excecao na VENDA ' + LSymbol + ': ' + E.Message;
        TThread.Queue(nil, procedure
        begin
          FSellingSymbols.Remove(LSymbol);
          AddLog('Erro', LErr);
          var DE := TJSONObject.Create;
          DE.AddPair('message', LErr);
          SendToJS('tradeError', DE);
        end);
      end;
    end;
  end).Start;
end;

{ ================================================================
  BOT
  ================================================================ }

procedure TfrmMain.DoStartBot;
var D: TJSONObject;
begin
  if FBotRunning then Exit;
  FBotRunning := True;
  FBotCoinIndex := 0;
  FTimerBot.Interval := Round(GetCfgDbl('botInterval', 180)) * 1000;
  FTimerBot.Enabled := True;
  D := TJSONObject.Create;
  D.AddPair('running', TJSONBool.Create(True));
  SendToJS('botStatus', D);
  AddLog('Bot', Format('INICIADO - intervalo %ds | %d moedas no scan', [Round(GetCfgDbl('botInterval', 180)), Length(FTopCoins)]));
  Caption := 'Binance Recovery Bot [BOT ATIVO]';
end;

procedure TfrmMain.DoStopBot;
var D: TJSONObject;
begin
  FBotRunning := False;
  FTimerBot.Enabled := False;
  D := TJSONObject.Create;
  D.AddPair('running', TJSONBool.Create(False));
  SendToJS('botStatus', D);
  AddLog('Bot', 'PARADO');
  Caption := 'Binance Recovery Bot';
end;

{ ================================================================
  TEST CONNECTION
  ================================================================ }

procedure TfrmMain.DoTestConnection;
begin
  AddLog('Binance', 'Testando conexao...');
  // Log diagnostico: mostra modo, URL e chave
  if FBinance.UseTestnet then
    AddLog('Binance', 'Modo: TESTNET | URL base: https://testnet.binance.vision/api')
  else
    AddLog('Binance', 'Modo: PRODUCAO | URL base: https://api.binance.com/api');
  if Length(FBinance.ApiKey) > 8 then
    AddLog('Binance', Format('API Key: %s...%s (%d chars)',
      [Copy(FBinance.ApiKey, 1, 4), Copy(FBinance.ApiKey, Length(FBinance.ApiKey)-3, 4), Length(FBinance.ApiKey)]))
  else if FBinance.ApiKey = '' then
    AddLog('Erro', 'API Key esta VAZIA! Configure em Configuracoes.')
  else
    AddLog('Erro', Format('API Key muito curta: %d chars', [Length(FBinance.ApiKey)]));

  TThread.CreateAnonymousThread(procedure
  var
    LPingOK, LAuthOK: Boolean;
    LAccResp: TJSONValue;
    LAuthErr: string;
  begin
    try
      // 1. Sync e Ping (rede)
      FBinance.SyncServerTime;
      LPingOK := FBinance.TestConnectivity;

      // 2. Teste autenticado (API key)
      LAuthOK := False;
      LAuthErr := '';
      if LPingOK then
      begin
        LAccResp := FBinance.DoRequest('GET', '/v3/account', '', True);
        try
          if (LAccResp <> nil) and (LAccResp is TJSONObject) then
          begin
            if TJSONObject(LAccResp).FindValue('balances') <> nil then
              LAuthOK := True
            else
              LAuthErr := TJSONObject(LAccResp).GetValue<string>('msg', 'Resposta inesperada');
          end
          else
            LAuthErr := 'Sem resposta do servidor';
        finally
          LAccResp.Free;
        end;
      end;

      TThread.Queue(nil, procedure
      var DC: TJSONObject;
      begin
        DC := TJSONObject.Create;
        DC.AddPair('connected', TJSONBool.Create(LPingOK and LAuthOK));
        DC.AddPair('testnet', TJSONBool.Create(GetCfgBool('testnet', True)));
        DC.AddPair('authOK', TJSONBool.Create(LAuthOK));
        SendToJS('connectionStatus', DC);

        FApiKeyValid := LAuthOK;

        if not LPingOK then
          AddLog('Erro', 'Falha na conexao de rede com a Binance')
        else if not LAuthOK then
          AddLog('Erro', 'API Key INVALIDA: ' + LAuthErr + ' - Verifique suas chaves em Configuracoes')
        else
        begin
          AddLog('Binance', 'Conexao OK! API Key validada com sucesso.');
          UpdateBalance;
          DoLoadBinanceTrades;
        end;
      end);
    except
      on E: Exception do
      begin
        var LErr := 'Teste de conexao falhou: ' + E.Message;
        TThread.Queue(nil, procedure
        var DC: TJSONObject;
        begin
          DC := TJSONObject.Create;
          DC.AddPair('connected', TJSONBool.Create(False));
          DC.AddPair('testnet', TJSONBool.Create(GetCfgBool('testnet', True)));
          DC.AddPair('authOK', TJSONBool.Create(False));
          SendToJS('connectionStatus', DC);
          AddLog('Erro', LErr);
        end);
      end;
    end;
  end).Start;
end;

{ ================================================================
  SAVE CONFIG
  ================================================================ }

procedure TfrmMain.DoSaveConfig(Data: TJSONObject);
var
  LNewTestnet, LOldTestnet: Boolean;
  LNewDbPath: string;
  LTradesArr: TJSONArray;
  LTradesData, LSnapData: TJSONObject;
  LSnapshotsArr: TJSONArray;
begin
  if Data = nil then Exit;

  LOldTestnet := GetCfgBool('testnet', True);

  // Merge Data no FConfig existente (preserva chaves nao enviadas pelo JS)
  for var I := 0 to Data.Count - 1 do
  begin
    var LKey := Data.Pairs[I].JsonString.Value;
    var LVal := Data.Pairs[I].JsonValue.Clone as TJSONValue;
    var LOld := FConfig.RemovePair(LKey);
    LOld.Free;
    FConfig.AddPair(LKey, LVal);
  end;

  LNewTestnet := GetCfgBool('testnet', True);

  // Seleciona chaves conforme modo
  if LNewTestnet then
  begin
    FBinance.ApiKey := GetCfgStr('apiKeyTest', '');
    FBinance.SecretKey := GetCfgStr('secretKeyTest', '');
  end
  else
  begin
    FBinance.ApiKey := GetCfgStr('apiKeyProd', '');
    FBinance.SecretKey := GetCfgStr('secretKeyProd', '');
  end;
  FBinance.UseTestnet := LNewTestnet;
  FBinance.UpdateBaseURL;

  // Se o modo ou chaves mudaram, resetar validacao
  FApiKeyValid := False;

  // Se o modo mudou, trocar o banco de dados
  if LOldTestnet <> LNewTestnet then
  begin
    FreeAndNil(FDB);
    LNewDbPath := DbPathForMode(LNewTestnet);
    FDB := TDatabase.Create(LNewDbPath);

    // Recarregar posicoes abertas do novo banco
    FreeAndNil(FOpenPositions);
    FOpenPositions := FDB.LoadPositions;
    // Resetar rastreamento ao trocar modo
    FSymbolFirstEntry.Clear;
    FLateralBlacklist.Clear;
    for var PIdx := 0 to FOpenPositions.Count - 1 do
      if not FSymbolFirstEntry.ContainsKey(FOpenPositions[PIdx].Symbol) then
        FSymbolFirstEntry.AddOrSetValue(FOpenPositions[PIdx].Symbol, FOpenPositions[PIdx].BuyTime);

    // Recarregar cache IA do novo banco
    FreeAndNil(FAICache);
    FAICache := FDB.LoadAICache;

    // Recarregar trades do novo banco e enviar ao JS
    LTradesArr := FDB.LoadTrades;
    LTradesData := TJSONObject.Create;
    LTradesData.AddPair('trades', LTradesArr);
    SendToJS('loadTrades', LTradesData);

    // Recarregar snapshots do novo banco e enviar ao JS
    LSnapshotsArr := FDB.LoadWalletSnapshots(500);
    LSnapData := TJSONObject.Create;
    LSnapData.AddPair('snapshots', LSnapshotsArr);
    SendToJS('walletSnapshots', LSnapData);

    if LNewTestnet then
      AddLog('Sistema', 'Modo alterado para TESTNET - banco de dados de teste carregado')
    else
      AddLog('Sistema', 'Modo alterado para PRODUCAO - banco de dados de producao carregado');
  end;

  FAIEngine.ApiKey := GetCfgStr('aiKey', '');
  FAIEngine.Model := GetCfgStr('aiModel', 'gpt-4o-mini');
  FAIEngine.UseVision := GetCfgBool('aiVision', False);
  var LURL := GetCfgStr('aiBaseURL', '');
  if LURL <> '' then FAIEngine.BaseURL := LURL
  else FAIEngine.BaseURL := 'https://api.openai.com/v1';

  // Atualiza intervalo dos timers se alterado
  var LBotInt := Round(GetCfgDbl('botInterval', 180));
  if LBotInt < 30 then LBotInt := 30;
  FTimerBot.Interval := LBotInt * 1000;
  var LSnapInt := Round(GetCfgDbl('snapshotInterval', 30));
  if LSnapInt < 5 then LSnapInt := 5;
  FTimerWallet.Interval := LSnapInt * 60000;

  SaveConfig;
  AddLog('Sistema', 'Configuracoes salvas! Validando API Key...');

  // Valida automaticamente a API Key ao salvar
  DoTestConnection;
end;

{ ================================================================
  UPDATES -> JS
  ================================================================ }

procedure TfrmMain.UpdatePrice;
begin
  if FSelectedSymbol = '' then Exit;
  TThread.CreateAnonymousThread(procedure
  var LPrice: Double; LSym: string;
  begin
    LSym := FSelectedSymbol;
    try
      LPrice := FBinance.GetPrice(LSym);
      if LPrice > 0 then
      begin
        FLastIndicators.CurrentPrice := LPrice;
        TThread.Queue(nil, procedure
        var DP: TJSONObject;
            PI: Integer;
        begin
          DP := TJSONObject.Create;
          DP.AddPair('price', TJSONNumber.Create(LPrice));
          DP.AddPair('symbol', LSym);
          SendToJS('updatePrice', DP);

          // Verifica trailing stop e take profit em tempo real (sem API extra)
          // Agrupa TODAS as posicoes DCA do symbol (preco medio ponderado)
          if FBotRunning and (FOpenPositions.Count > 0) then
          begin
            var LTrailPct := GetCfgDbl('trailingStop', 3);
            var LTPPct := GetCfgDbl('takeProfit', 8);
            var LTotalQty: Double := 0;
            var LTotalCost: Double := 0;
            var LHighest: Double := 0;
            var LEarliest: TDateTime := Now;
            var LFound := False;
            for PI := 0 to FOpenPositions.Count - 1 do
              if (FOpenPositions[PI].Symbol = LSym) and (FOpenPositions[PI].BuyPrice > 0) then
              begin
                LFound := True;
                LTotalQty := LTotalQty + FOpenPositions[PI].Quantity;
                LTotalCost := LTotalCost + (FOpenPositions[PI].BuyPrice * FOpenPositions[PI].Quantity);
                if FOpenPositions[PI].HighestPrice > LHighest then
                  LHighest := FOpenPositions[PI].HighestPrice;
                if FOpenPositions[PI].BuyTime < LEarliest then
                  LEarliest := FOpenPositions[PI].BuyTime;
              end;

            if LFound and (LTotalQty > 0) then
            begin
              var LAvgPrice := LTotalCost / LTotalQty;
              var LGainPct := ((LPrice - LAvgPrice) / LAvgPrice) * 100;

              // Atualiza pico em todas as posicoes do symbol
              if LPrice > LHighest then
              begin
                LHighest := LPrice;
                for PI := 0 to FOpenPositions.Count - 1 do
                  if (FOpenPositions[PI].Symbol = LSym) and (LPrice > FOpenPositions[PI].HighestPrice) then
                  begin
                    var LPos := FOpenPositions[PI];
                    LPos.HighestPrice := LPrice;
                    FOpenPositions[PI] := LPos;
                  end;
                try FDB.UpdatePositionHighPrice(LSym, LPrice); except end;
              end;

              // Take Profit: vende TODAS as posicoes ao atingir o % configurado
              if (LTPPct > 0) and (LGainPct >= LTPPct) and (MinutesBetween(Now, LEarliest) >= 5) then
              begin
                AddLog('TakeProfit', Format(
                  'TAKE PROFIT: %s | Medio: $%s | Ganho: +%.2f%% (meta: %.1f%%) | Vendendo!',
                  [LSym, FormatFloat('0.####', LAvgPrice, FmtDot), LGainPct, LTPPct], FmtDot));
                DoSell(LTotalQty * LPrice);
                FLastTradeTime.AddOrSetValue(LSym, Now);
              end
              // Trailing Stop: vende TODAS se cair X% do pico
              else if (LTrailPct > 0) and (LHighest > 0) then
              begin
                var LDrop := ((LHighest - LPrice) / LHighest) * 100;
                if (LDrop >= LTrailPct) and (MinutesBetween(Now, LEarliest) >= 5) then
                begin
                  AddLog('TrailingStop', Format(
                    'TRAILING STOP: %s | Medio: $%s | Pico: $%s | Queda: -%.2f%% | P&L: %.2f%% | Vendendo!',
                    [LSym, FormatFloat('0.####', LAvgPrice, FmtDot),
                     FormatFloat('0.####', LHighest, FmtDot), LDrop, LGainPct], FmtDot));
                  DoSell(LTotalQty * LPrice);
                  FLastTradeTime.AddOrSetValue(LSym, Now);
                end;
              end;
            end;
          end;
        end);
      end;
    except end;
  end).Start;
end;

procedure TfrmMain.UpdateBalance;
begin
  if FSelectedSymbol = '' then Exit;
  TThread.CreateAnonymousThread(procedure
  var
    LQuote: TAssetBalance;
    LSym, LQuoteAsset: string;
  begin
    LSym := FSelectedSymbol;
    if LSym.EndsWith('USDT') then LQuoteAsset := 'USDT'
    else if LSym.EndsWith('BTC') then LQuoteAsset := 'BTC'
    else LQuoteAsset := 'USDT';

    var LBaseAsset: string;
    if LSym.EndsWith('USDT') then LBaseAsset := Copy(LSym, 1, Length(LSym) - 4)
    else if LSym.EndsWith('BTC') then LBaseAsset := Copy(LSym, 1, Length(LSym) - 3)
    else LBaseAsset := LSym;

    try
      var LBase := FBinance.GetBalance(LBaseAsset);
      LQuote := FBinance.GetBalance(LQuoteAsset);
      TThread.Queue(nil, procedure
      var DB: TJSONObject;
      begin
        DB := TJSONObject.Create;
        DB.AddPair('baseAsset',   LBase.Asset);
        DB.AddPair('quoteAsset',  LQuote.Asset);
        DB.AddPair('baseFree',    TJSONNumber.Create(LBase.Free));
        DB.AddPair('baseLocked',  TJSONNumber.Create(LBase.Locked));
        DB.AddPair('quoteFree',   TJSONNumber.Create(LQuote.Free));
        DB.AddPair('quoteLocked', TJSONNumber.Create(LQuote.Locked));
        SendToJS('updateBalance', DB);
      end);
    except
      on E: Exception do
      begin
        var LErr := 'Saldo: ' + E.Message;
        TThread.Queue(nil, procedure begin AddLog('Erro', LErr); end);
      end;
    end;
  end).Start;
end;

procedure TfrmMain.DoLoadBinanceTrades;
begin
  if not FApiKeyValid then
  begin
    AddLog('Erro', 'API Key nao validada para buscar trades');
    Exit;
  end;

  AddLog('Sistema', 'Buscando historico de trades da Binance...');

  TThread.CreateAnonymousThread(procedure
  var
    LSymbols: TArray<string>;
    LAllTrades: TJSONArray;
    SI: Integer;
    LTrades: TJSONArray;
    TI: Integer;
    LTrade: TJSONObject;
    LObj: TJSONObject;
    LSide: string;
    LTime: TDateTime;
  begin
    try
      // Pega symbols do banco local + posicoes abertas
      LSymbols := FDB.GetTradedSymbols;
      // Adiciona symbols das posicoes abertas que podem nao estar no banco
      TThread.Synchronize(nil, procedure
      begin
        for var PI := 0 to FOpenPositions.Count - 1 do
        begin
          var LSym := FOpenPositions[PI].Symbol;
          var LFound := False;
          for var SI2 := 0 to High(LSymbols) do
            if LSymbols[SI2] = LSym then begin LFound := True; Break; end;
          if not LFound then
          begin
            SetLength(LSymbols, Length(LSymbols) + 1);
            LSymbols[High(LSymbols)] := LSym;
          end;
        end;
      end);

      LAllTrades := TJSONArray.Create;
      try
        for SI := 0 to High(LSymbols) do
        begin
          LTrades := FBinance.GetMyTrades(LSymbols[SI], 20);
          try
            for TI := 0 to LTrades.Count - 1 do
            begin
              LTrade := TJSONObject(LTrades.Items[TI]);
              LObj := TJSONObject.Create;
              // Binance retorna time em ms epoch
              LTime := UnixToDateTime(LTrade.GetValue<Int64>('time', 0) div 1000, False);
              LObj.AddPair('timestamp', FormatDateTime('dd/mm/yyyy hh:nn:ss', LTime));
              LObj.AddPair('symbol', LTrade.GetValue<string>('symbol', ''));
              if LTrade.GetValue<Boolean>('isBuyer', False) then
                LSide := 'BUY'
              else
                LSide := 'SELL';
              LObj.AddPair('side', LSide);
              LObj.AddPair('price', TJSONNumber.Create(
                StrToFloatDef(LTrade.GetValue<string>('price', '0'), 0, FmtDot)));
              LObj.AddPair('quantity', TJSONNumber.Create(
                StrToFloatDef(LTrade.GetValue<string>('qty', '0'), 0, FmtDot)));
              LObj.AddPair('commission', TJSONNumber.Create(
                StrToFloatDef(LTrade.GetValue<string>('commission', '0'), 0, FmtDot)));
              LObj.AddPair('commissionAsset', LTrade.GetValue<string>('commissionAsset', ''));
              LObj.AddPair('orderId', TJSONNumber.Create(LTrade.GetValue<Int64>('orderId', 0)));
              LObj.AddPair('signal', '--');
              LObj.AddPair('confidence', TJSONNumber.Create(0));
              LAllTrades.AddElement(LObj);
            end;
          finally
            LTrades.Free;
          end;
        end;

        // Ordena por timestamp descendente (mais recente primeiro)
        var LTradeData := TJSONObject.Create;
        LTradeData.AddPair('trades', LAllTrades.Clone as TJSONArray);
        LTradeData.AddPair('source', 'binance');

        var LCount := LAllTrades.Count;
        var LSymCount := Length(LSymbols);
        TThread.Synchronize(nil, procedure
        begin
          SendToJS('loadTrades', LTradeData);
          AddLog('Sistema', Format('Historico Binance: %d trades de %d moedas', [LCount, LSymCount]));
        end);
      finally
        LAllTrades.Free;
      end;
    except
      on E: Exception do
      begin
        var LErr := 'Erro ao buscar trades: ' + E.Message;
        TThread.Synchronize(nil, procedure begin AddLog('Erro', LErr); end);
      end;
    end;
  end).Start;
end;

procedure TfrmMain.DoRegisterPosition(const Symbol: string);
begin
  if Symbol = '' then Exit;

  TThread.CreateAnonymousThread(procedure
  var
    LAsset: string;
    LBal: TAssetBalance;
    LPrice, LQty: Double;
    LAlreadyTracked: Boolean;
  begin
    LAsset := Symbol.Replace('USDT', '');

    // Verifica se ja esta rastreada
    LAlreadyTracked := False;
    TThread.Synchronize(nil, procedure
    begin
      for var I := 0 to FOpenPositions.Count - 1 do
        if FOpenPositions[I].Symbol = Symbol then
        begin
          LAlreadyTracked := True;
          Break;
        end;
    end);

    if LAlreadyTracked then
    begin
      TThread.Queue(nil, procedure
      begin
        AddLog('Posicao', Symbol + ' ja esta registrada como posicao aberta');
      end);
      Exit;
    end;

    // Busca saldo e preco
    try
      LBal := FBinance.GetBalance(LAsset);
      LQty := LBal.Free + LBal.Locked;
      if LQty <= 0 then
      begin
        TThread.Queue(nil, procedure
        begin
          AddLog('Erro', 'Sem saldo de ' + LAsset + ' para registrar');
        end);
        Exit;
      end;

      LPrice := FBinance.GetPrice(Symbol);
      if LPrice <= 0 then
      begin
        TThread.Queue(nil, procedure
        begin
          AddLog('Erro', 'Nao foi possivel obter preco de ' + Symbol);
        end);
        Exit;
      end;
    except
      on E: Exception do
      begin
        var LErrMsg := 'Erro ao registrar posicao: ' + E.Message;
        TThread.Queue(nil, procedure begin AddLog('Erro', LErrMsg); end);
        Exit;
      end;
    end;

    // Registra posicao
    TThread.Queue(nil, procedure
    var
      LPos: TOpenPosition;
    begin
      LPos.Symbol := Symbol;
      LPos.BuyPrice := LPrice;
      LPos.BuyTime := Now;
      LPos.Quantity := LQty;
      LPos.HighestPrice := LPrice;
      FOpenPositions.Add(LPos);
      try
        FDB.SavePosition(Symbol, LPrice, Now, LQty, LPrice);
      except end;

      if not FSymbolFirstEntry.ContainsKey(Symbol) then
        FSymbolFirstEntry.AddOrSetValue(Symbol, Now);

      AddLog('Posicao', Format('REGISTRADA: %s | Preco: $%s | Qty: %s | Valor: $%.2f',
        [Symbol,
         FormatFloat('0.########', LPrice, FmtDot),
         FormatFloat('0.########', LQty, FmtDot),
         LQty * LPrice]));
      SendTelegram(Format(
        '&#x1F4CB; <b>POSICAO REGISTRADA</b> %s'#10 +
        'Preco: $%s | Qty: %s'#10 +
        'Valor: $%.2f',
        [Symbol,
         FormatFloat('0.####', LPrice, FmtDot),
         FormatFloat('0.####', LQty, FmtDot),
         LQty * LPrice]));
    end);
  end).Start;
end;

procedure TfrmMain.DoGetAllSymbols;
begin
  TThread.CreateAnonymousThread(procedure
  var
    LTickers: TJSONArray;
    LArr: TJSONArray;
    I: Integer;
    LObj: TJSONObject;
    LSym, LPrice, LChange, LVol: string;
    LData: TJSONObject;
    // Para ordenacao por volume
    LList: TList<TPair<Double, TJSONObject>>;
    LVolD: Double;
  begin
    try
      LTickers := FBinance.GetAll24hTickers;
      if LTickers = nil then
      begin
        TThread.Queue(nil, procedure begin AddLog('Erro', 'Falha ao buscar tickers'); end);
        Exit;
      end;
      try
        LList := TList<TPair<Double, TJSONObject>>.Create;
        try
          for I := 0 to LTickers.Count - 1 do
          begin
            LObj := LTickers.Items[I] as TJSONObject;
            LSym := LObj.GetValue<string>('symbol', '');
            if not LSym.EndsWith('USDT') then Continue;
            // Filtra tokens alavancados (BTCUPUSDT, ETHDOWNUSDT, etc.)
            if LSym.EndsWith('UPUSDT') or LSym.EndsWith('DOWNUSDT')
              or LSym.EndsWith('BULLUSDT') or LSym.EndsWith('BEARUSDT') then Continue;

            LPrice := LObj.GetValue<string>('lastPrice', '0');
            LChange := LObj.GetValue<string>('priceChangePercent', '0');
            LVol := LObj.GetValue<string>('quoteVolume', '0');
            LVolD := StrToFloatDef(LVol, 0, FmtDot);

            var LItem := TJSONObject.Create;
            LItem.AddPair('symbol', LSym);
            LItem.AddPair('price', LPrice);
            LItem.AddPair('change', LChange);
            LItem.AddPair('volume', LVol);
            LList.Add(TPair<Double, TJSONObject>.Create(LVolD, LItem));
          end;

          // Ordena por volume DESC
          LList.Sort(TComparer<TPair<Double, TJSONObject>>.Construct(
            function(const A, B: TPair<Double, TJSONObject>): Integer
            begin
              if A.Key > B.Key then Result := -1
              else if A.Key < B.Key then Result := 1
              else Result := 0;
            end));

          LArr := TJSONArray.Create;
          for I := 0 to LList.Count - 1 do
            LArr.AddElement(LList[I].Value);

          LData := TJSONObject.Create;
          LData.AddPair('symbols', LArr);

          TThread.Queue(nil, procedure
          begin
            SendToJS('allSymbols', LData);
          end);
        finally
          LList.Free;
        end;
      finally
        LTickers.Free;
      end;
    except
      on E: Exception do
      begin
        var LErrMsg := 'Erro ao buscar symbols: ' + E.Message;
        TThread.Queue(nil, procedure begin AddLog('Erro', LErrMsg); end);
      end;
    end;
  end).Start;
end;

procedure TfrmMain.DoCoinHistory(const Symbol: string);
begin
  if Symbol = '' then Exit;

  TThread.CreateAnonymousThread(procedure
  var
    LCandles1h, LCandles24h: TCandleArray;
    LTicker: TJSONObject;
    D: TJSONObject;
    A1h, A24h: TJSONArray;
    C: TJSONObject;
    I: Integer;
    LLastPrice, LPriceChange, LPriceChangePct: Double;
    LHighPrice, LLowPrice, LVolume, LQuoteVolume: Double;
  begin
    try
      // 1h de candles de 1 minuto (60 pontos)
      LCandles1h := FBinance.GetKlines(Symbol, '1m', 60);
      // 24h de candles de 15 minutos (96 pontos)
      LCandles24h := FBinance.GetKlines(Symbol, '15m', 96);

      // Stats 24h
      LLastPrice := 0; LPriceChange := 0; LPriceChangePct := 0;
      LHighPrice := 0; LLowPrice := 0; LVolume := 0; LQuoteVolume := 0;
      LTicker := FBinance.Get24hTicker(Symbol);
      try
        if LTicker <> nil then
        begin
          LLastPrice := StrToFloatDef(LTicker.GetValue<string>('lastPrice', '0'), 0, FmtDot);
          LPriceChange := StrToFloatDef(LTicker.GetValue<string>('priceChange', '0'), 0, FmtDot);
          LPriceChangePct := StrToFloatDef(LTicker.GetValue<string>('priceChangePercent', '0'), 0, FmtDot);
          LHighPrice := StrToFloatDef(LTicker.GetValue<string>('highPrice', '0'), 0, FmtDot);
          LLowPrice := StrToFloatDef(LTicker.GetValue<string>('lowPrice', '0'), 0, FmtDot);
          LVolume := StrToFloatDef(LTicker.GetValue<string>('volume', '0'), 0, FmtDot);
          LQuoteVolume := StrToFloatDef(LTicker.GetValue<string>('quoteVolume', '0'), 0, FmtDot);
        end;
      finally
        LTicker.Free;
      end;

      // Monta JSON compacto
      D := TJSONObject.Create;
      try
        D.AddPair('symbol', Symbol);
        D.AddPair('lastPrice', TJSONNumber.Create(LLastPrice));
        D.AddPair('priceChange', TJSONNumber.Create(LPriceChange));
        D.AddPair('priceChangePct', TJSONNumber.Create(LPriceChangePct));
        D.AddPair('highPrice', TJSONNumber.Create(LHighPrice));
        D.AddPair('lowPrice', TJSONNumber.Create(LLowPrice));
        D.AddPair('volume', TJSONNumber.Create(LVolume));
        D.AddPair('quoteVolume', TJSONNumber.Create(LQuoteVolume));

        // Candles 1h (1m interval)
        A1h := TJSONArray.Create;
        for I := 0 to High(LCandles1h) do
        begin
          C := TJSONObject.Create;
          C.AddPair('o', TJSONNumber.Create(LCandles1h[I].Open));
          C.AddPair('h', TJSONNumber.Create(LCandles1h[I].High));
          C.AddPair('l', TJSONNumber.Create(LCandles1h[I].Low));
          C.AddPair('c', TJSONNumber.Create(LCandles1h[I].Close));
          C.AddPair('v', TJSONNumber.Create(LCandles1h[I].Volume));
          C.AddPair('t', TJSONNumber.Create(DateTimeToUnix(LCandles1h[I].OpenTime, False) * Int64(1000)));
          A1h.AddElement(C);
        end;
        D.AddPair('candles1h', A1h);

        // Candles 24h (15m interval)
        A24h := TJSONArray.Create;
        for I := 0 to High(LCandles24h) do
        begin
          C := TJSONObject.Create;
          C.AddPair('o', TJSONNumber.Create(LCandles24h[I].Open));
          C.AddPair('h', TJSONNumber.Create(LCandles24h[I].High));
          C.AddPair('l', TJSONNumber.Create(LCandles24h[I].Low));
          C.AddPair('c', TJSONNumber.Create(LCandles24h[I].Close));
          C.AddPair('v', TJSONNumber.Create(LCandles24h[I].Volume));
          C.AddPair('t', TJSONNumber.Create(DateTimeToUnix(LCandles24h[I].OpenTime, False) * Int64(1000)));
          A24h.AddElement(C);
        end;
        D.AddPair('candles24h', A24h);

        TThread.Queue(nil, procedure
        begin
          SendToJS('coinHistoryData', D);
          D.Free;
        end);
      except
        D.Free;
        raise;
      end;
    except
      on E: Exception do
      begin
        var LErr := E.Message;
        TThread.Queue(nil, procedure
        var DEr: TJSONObject;
        begin
          DEr := TJSONObject.Create;
          DEr.AddPair('symbol', Symbol);
          DEr.AddPair('error', LErr);
          SendToJS('coinHistoryData', DEr);
          DEr.Free;
        end);
      end;
    end;
  end).Start;
end;

procedure TfrmMain.DoRefreshWallet;
var
  DLoading: TJSONObject;
begin
  if FRefreshingWallet then
  begin
    AddLog('Carteira', 'Atualizacao ja em andamento...');
    Exit;
  end;

  FRefreshingWallet := True;
  DLoading := TJSONObject.Create;
  DLoading.AddPair('loading', TJSONBool.Create(True));
  SendToJS('walletLoading', DLoading);
  AddLog('Carteira', 'Carregando saldos...');

  TThread.CreateAnonymousThread(procedure
  var
    LBalances: TAssetBalanceArray;
    LTickers: TJSONArray;
    LPrices: TDictionary<string, Double>;
    I: Integer;
    LObj: TJSONObject;
    LSymbol: string;
    LPrice, LTotalUSDT, LAssetUSDT, LBtcUsdt: Double;
    DWallet: TJSONObject;
    ABalances: TJSONArray;
    BObj: TJSONObject;
  begin
    try
      LBalances := FBinance.GetAllBalances(0);

      LTickers := FBinance.GetAll24hTickers;
      LPrices := TDictionary<string, Double>.Create;
      try
        if LTickers <> nil then
        begin
          try
            for I := 0 to LTickers.Count - 1 do
            begin
              LObj := TJSONObject(LTickers.Items[I]);
              LSymbol := LObj.GetValue<string>('symbol', '');
              LPrice := StrToFloatDef(LObj.GetValue<string>('lastPrice', '0'), 0, FmtDot);
              if LPrice > 0 then
                LPrices.AddOrSetValue(LSymbol, LPrice);
            end;
          finally
            LTickers.Free;
          end;
        end;

        DWallet := TJSONObject.Create;
        ABalances := TJSONArray.Create;
        LTotalUSDT := 0;

        for I := 0 to High(LBalances) do
        begin
          BObj := TJSONObject.Create;
          BObj.AddPair('asset', LBalances[I].Asset);
          BObj.AddPair('free', TJSONNumber.Create(LBalances[I].Free));
          BObj.AddPair('locked', TJSONNumber.Create(LBalances[I].Locked));

          LAssetUSDT := 0;
          if (LBalances[I].Asset = 'USDT') or (LBalances[I].Asset = 'BUSD') or
             (LBalances[I].Asset = 'USDC') or (LBalances[I].Asset = 'FDUSD') then
            LAssetUSDT := LBalances[I].Free + LBalances[I].Locked
          else if LPrices.TryGetValue(LBalances[I].Asset + 'USDT', LPrice) then
            LAssetUSDT := (LBalances[I].Free + LBalances[I].Locked) * LPrice
          else if LPrices.TryGetValue(LBalances[I].Asset + 'BTC', LPrice) then
          begin
            if LPrices.TryGetValue('BTCUSDT', LBtcUsdt) then
              LAssetUSDT := (LBalances[I].Free + LBalances[I].Locked) * LPrice * LBtcUsdt;
          end;

          BObj.AddPair('valueUSDT', TJSONNumber.Create(LAssetUSDT));
          LTotalUSDT := LTotalUSDT + LAssetUSDT;
          ABalances.AddElement(BObj);
        end;

        DWallet.AddPair('totalUSDT', TJSONNumber.Create(LTotalUSDT));
        DWallet.AddPair('balances', ABalances);

        TThread.Queue(nil, procedure
        var DEnd, DSnap: TJSONObject;
        begin
          SendToJS('walletData', DWallet);
          AddLog('Carteira', Format('Carregada: %d ativos, Total: $%.2f USDT',
            [Length(LBalances), LTotalUSDT], FmtDot));

          // Salvar snapshot no banco
          if LTotalUSDT > 0 then
          begin
            FDB.SaveWalletSnapshot(LTotalUSDT, Now);
            DSnap := TJSONObject.Create;
            DSnap.AddPair('timestamp', FormatDateTime('yyyy-mm-dd hh:nn:ss', Now));
            DSnap.AddPair('totalUSDT', TJSONNumber.Create(LTotalUSDT));
            SendToJS('walletSnapshotAdd', DSnap);
          end;

          FRefreshingWallet := False;
          DEnd := TJSONObject.Create;
          DEnd.AddPair('loading', TJSONBool.Create(False));
          SendToJS('walletLoading', DEnd);
        end);
      finally
        LPrices.Free;
      end;
    except
      on E: Exception do
      begin
        var LErr := 'Carteira: ' + E.Message;
        TThread.Queue(nil, procedure
        var DEnd: TJSONObject;
        begin
          AddLog('Erro', LErr);
          FRefreshingWallet := False;
          DEnd := TJSONObject.Create;
          DEnd.AddPair('loading', TJSONBool.Create(False));
          SendToJS('walletLoading', DEnd);
        end);
      end;
    end;
  end).Start;
end;

procedure TfrmMain.SendCandles;
var
  D: TJSONObject;
  A: TJSONArray;
  I, S: Integer;
  C: TJSONObject;
begin
  D := TJSONObject.Create;
  A := TJSONArray.Create;
  S := Max(0, Length(FLastCandles) - 50);
  for I := S to High(FLastCandles) do
  begin
    C := TJSONObject.Create;
    C.AddPair('o', TJSONNumber.Create(FLastCandles[I].Open));
    C.AddPair('h', TJSONNumber.Create(FLastCandles[I].High));
    C.AddPair('l', TJSONNumber.Create(FLastCandles[I].Low));
    C.AddPair('c', TJSONNumber.Create(FLastCandles[I].Close));
    C.AddPair('v', TJSONNumber.Create(FLastCandles[I].Volume));
    C.AddPair('t', TJSONNumber.Create(DateTimeToUnix(FLastCandles[I].OpenTime, False) * Int64(1000)));
    A.AddElement(C);
  end;
  D.AddPair('candles', A);
  SendToJS('updateCandles', D);
end;

procedure TfrmMain.SendIndicators;
var D: TJSONObject; L: TTechnicalIndicators;
begin
  L := FLastIndicators;
  D := TJSONObject.Create;
  D.AddPair('rsi',             TJSONNumber.Create(L.RSI));
  D.AddPair('macd',            TJSONNumber.Create(L.MACD));
  D.AddPair('macdSignal',      TJSONNumber.Create(L.MACDSignal));
  D.AddPair('macdHistogram',   TJSONNumber.Create(L.MACDHistogram));
  D.AddPair('sma20',           TJSONNumber.Create(L.SMA20));
  D.AddPair('sma50',           TJSONNumber.Create(L.SMA50));
  D.AddPair('ema12',           TJSONNumber.Create(L.EMA12));
  D.AddPair('ema26',           TJSONNumber.Create(L.EMA26));
  D.AddPair('bollingerUpper',  TJSONNumber.Create(L.BollingerUpper));
  D.AddPair('bollingerMiddle', TJSONNumber.Create(L.BollingerMiddle));
  D.AddPair('bollingerLower',  TJSONNumber.Create(L.BollingerLower));
  D.AddPair('atr',             TJSONNumber.Create(L.ATR));
  D.AddPair('volume24h',       TJSONNumber.Create(L.Volume24h));
  D.AddPair('priceChange24h',  TJSONNumber.Create(L.PriceChange24h));
  D.AddPair('techScore',       TJSONNumber.Create(TTechnicalAnalysis.TechnicalScore(L)));
  SendToJS('updateIndicators', D);
end;

procedure TfrmMain.SendSignal;
var D: TJSONObject; A: TAIAnalysis;
begin
  A := FLastAnalysis;
  D := TJSONObject.Create;
  D.AddPair('signal',     SignalToStrEN(A.Signal));
  D.AddPair('confidence', TJSONNumber.Create(A.Confidence));
  D.AddPair('reasoning',  A.Reasoning);
  D.AddPair('entry',      TJSONNumber.Create(A.SuggestedEntry));
  D.AddPair('stopLoss',   TJSONNumber.Create(A.SuggestedStopLoss));
  D.AddPair('takeProfit', TJSONNumber.Create(A.SuggestedTakeProfit));
  SendToJS('updateSignal', D);
end;

{ ================================================================
  TELEGRAM
  ================================================================ }

procedure TfrmMain.SendTelegram(const Msg: string);
var
  LToken, LChatId: string;
begin
  if not GetCfgBool('telegramEnabled', False) then Exit;
  LToken := GetCfgStr('telegramToken', '');
  LChatId := GetCfgStr('telegramChatId', '');
  if (LToken = '') or (LChatId = '') then Exit;

  // Captura valores locais para a thread
  var LTok := LToken;
  var LCid := LChatId;
  var LMsg := Msg;
  TThread.CreateAnonymousThread(procedure
  var
    Http: THTTPClient;
    Body: TStringStream;
    JBody: TJSONObject;
  begin
    Http := THTTPClient.Create;
    try
      Http.ConnectionTimeout := 5000;
      Http.ResponseTimeout := 10000;
      JBody := TJSONObject.Create;
      try
        JBody.AddPair('chat_id', LCid);
        JBody.AddPair('text', LMsg);
        JBody.AddPair('parse_mode', 'HTML');
        Body := TStringStream.Create(JBody.ToJSON, TEncoding.UTF8);
        try
          Http.Post(
            'https://api.telegram.org/bot' + LTok + '/sendMessage',
            Body, nil,
            [TNetHeader.Create('Content-Type', 'application/json')]);
        finally
          Body.Free;
        end;
      finally
        JBody.Free;
      end;
    finally
      Http.Free;
    end;
  end).Start;
end;

procedure TfrmMain.SendTelegramPhoto(const Caption, Base64Png: string);
var
  LToken, LChatId: string;
begin
  if not GetCfgBool('telegramEnabled', False) then Exit;
  LToken := GetCfgStr('telegramToken', '');
  LChatId := GetCfgStr('telegramChatId', '');
  if (LToken = '') or (LChatId = '') then Exit;
  if Base64Png = '' then
  begin
    SendTelegram(Caption);
    Exit;
  end;

  var LTok := LToken;
  var LCid := LChatId;
  var LCap := Caption;
  var LB64 := Base64Png;
  TThread.CreateAnonymousThread(procedure
  var
    Http: THTTPClient;
    FormData: TMultipartFormData;
    PngBytes: TBytes;
    PngStream: TBytesStream;
  begin
    Http := THTTPClient.Create;
    try
      Http.ConnectionTimeout := 10000;
      Http.ResponseTimeout := 30000;
      PngBytes := TNetEncoding.Base64.DecodeStringToBytes(LB64);
      PngStream := TBytesStream.Create(PngBytes);
      try
        FormData := TMultipartFormData.Create;
        try
          FormData.AddField('chat_id', LCid);
          FormData.AddField('caption', LCap);
          FormData.AddField('parse_mode', 'HTML');
          FormData.AddStream('photo', PngStream, 'chart.png', 'image/png');
          Http.Post(
            'https://api.telegram.org/bot' + LTok + '/sendPhoto',
            FormData);
        finally
          FormData.Free;
        end;
      finally
        PngStream.Free;
      end;
    finally
      Http.Free;
    end;
  end).Start;
end;

procedure TfrmMain.SendTelegramWithChart(const Caption, Symbol: string);
var
  LCap, LSym, LInt: string;
begin
  if not GetCfgBool('telegramEnabled', False) then Exit;
  LCap := Caption;
  LSym := Symbol;
  LInt := GetInterval;
  TThread.CreateAnonymousThread(procedure
  var
    LCandles: TCandleArray;
    LChart: string;
  begin
    LChart := '';
    try
      LCandles := FBinance.GetKlines(LSym, LInt, 60);
      if Length(LCandles) >= 10 then
        LChart := FAIEngine.GenerateChartBase64(LCandles);
    except
    end;
    SendTelegramPhoto(LCap, LChart);
  end).Start;
end;

{ ================================================================
  LOG
  ================================================================ }

procedure TfrmMain.AddLog(const Tag, Msg: string);
var D: TJSONObject;
begin
  D := TJSONObject.Create;
  D.AddPair('tag', Tag);
  D.AddPair('message', Msg);
  D.AddPair('time', FormatDateTime('hh:nn:ss', Now));
  SendToJS('addLog', D);
end;

{ ================================================================
  CONFIG
  ================================================================ }

function TfrmMain.GetCfgStr(const Key, Default: string): string;
begin Result := FConfig.GetValue<string>(Key, Default); end;

function TfrmMain.GetCfgBool(const Key: string; Default: Boolean): Boolean;
begin Result := FConfig.GetValue<Boolean>(Key, Default); end;

function TfrmMain.GetCfgDbl(const Key: string; Default: Double): Double;
begin Result := StrToFloatDef(FConfig.GetValue<string>(Key, FloatToStr(Default, FmtDot)), Default, FmtDot); end;

function TfrmMain.GetInterval: string;
begin Result := GetCfgStr('interval', '1h'); end;

procedure TfrmMain.LoadConfig;
var Ini: TIniFile;
begin
  Ini := TIniFile.Create(ExtractFilePath(Application.ExeName) + CONFIG_FILE);
  try
    FreeAndNil(FConfig);
    FConfig := TJSONObject.Create;
    FConfig.AddPair('apiKeyTest',     Ini.ReadString('Binance', 'ApiKeyTest', ''));
    FConfig.AddPair('secretKeyTest', Ini.ReadString('Binance', 'SecretKeyTest', ''));
    FConfig.AddPair('apiKeyProd',    Ini.ReadString('Binance', 'ApiKeyProd', ''));
    FConfig.AddPair('secretKeyProd', Ini.ReadString('Binance', 'SecretKeyProd', ''));
    FConfig.AddPair('testnet',       TJSONBool.Create(Ini.ReadBool('Binance', 'Testnet', True)));
    FConfig.AddPair('aiKey',         Ini.ReadString('AI', 'ApiKey', ''));
    FConfig.AddPair('aiModel',       Ini.ReadString('AI', 'Model', 'gpt-4o-mini'));
    FConfig.AddPair('aiVision',      TJSONBool.Create(Ini.ReadBool('AI', 'Vision', False)));
    FConfig.AddPair('aiBaseURL',     Ini.ReadString('AI', 'BaseURL', ''));
    FConfig.AddPair('aiCacheMins',   Ini.ReadString('AI', 'CacheMins', '15'));
    FConfig.AddPair('aiKeyOpenai',   Ini.ReadString('AI', 'KeyOpenai', ''));
    FConfig.AddPair('aiKeyGroq',     Ini.ReadString('AI', 'KeyGroq', ''));
    FConfig.AddPair('aiKeyMistral',  Ini.ReadString('AI', 'KeyMistral', ''));
    FConfig.AddPair('aiKeyCerebras', Ini.ReadString('AI', 'KeyCerebras', ''));
    FConfig.AddPair('aiKeyDeepseek', Ini.ReadString('AI', 'KeyDeepseek', ''));
    FConfig.AddPair('interval',      Ini.ReadString('Trading', 'Interval', '1h'));
    FConfig.AddPair('tradeAmount',   Ini.ReadString('Trading', 'Amount', '100'));
    FConfig.AddPair('trailingStop',   Ini.ReadString('Trading', 'TrailingStop', '3.0'));
    FConfig.AddPair('takeProfit',    Ini.ReadString('Trading', 'TakeProfit', '8.0'));
    FConfig.AddPair('minConfidence', Ini.ReadString('Trading', 'MinConfidence', '70'));
    FConfig.AddPair('minScore',      Ini.ReadString('Trading', 'MinScore', '25'));
    FConfig.AddPair('botInterval',   Ini.ReadString('Trading', 'BotInterval', '180'));
    FConfig.AddPair('autoTrade',     TJSONBool.Create(Ini.ReadBool('Trading', 'AutoTrade', False)));
    FConfig.AddPair('topCoins',         Ini.ReadString('Trading', 'TopCoins', '30'));
    FConfig.AddPair('scanMode',       Ini.ReadString('Trading', 'ScanMode', 'recovery'));
    FConfig.AddPair('recoveryHours',  Ini.ReadString('Trading', 'RecoveryHours', '24'));
    FConfig.AddPair('lateralTimeout', Ini.ReadString('Trading', 'LateralTimeout', '24'));
    FConfig.AddPair('tradeCooldown', Ini.ReadString('Trading', 'TradeCooldown', '30'));
    FConfig.AddPair('snapshotInterval', Ini.ReadString('Trading', 'SnapshotInterval', '30'));
    FConfig.AddPair('dcaEnabled',      TJSONBool.Create(Ini.ReadBool('DCA', 'Enabled', False)));
    FConfig.AddPair('dcaMax',          Ini.ReadString('DCA', 'Max', '3'));
    FConfig.AddPair('dcaLevel1',       Ini.ReadString('DCA', 'Level1', '3'));
    FConfig.AddPair('dcaLevel2',       Ini.ReadString('DCA', 'Level2', '5'));
    FConfig.AddPair('dcaLevel3',       Ini.ReadString('DCA', 'Level3', '8'));
    FConfig.AddPair('telegramEnabled', TJSONBool.Create(Ini.ReadBool('Telegram', 'Enabled', False)));
    FConfig.AddPair('telegramToken',   Ini.ReadString('Telegram', 'Token', ''));
    FConfig.AddPair('telegramChatId',  Ini.ReadString('Telegram', 'ChatId', ''));
  finally
    Ini.Free;
  end;
end;

procedure TfrmMain.SaveConfig;
var Ini: TIniFile;
begin
  Ini := TIniFile.Create(ExtractFilePath(Application.ExeName) + CONFIG_FILE);
  try
    Ini.WriteString('Binance', 'ApiKeyTest',     GetCfgStr('apiKeyTest', ''));
    Ini.WriteString('Binance', 'SecretKeyTest', GetCfgStr('secretKeyTest', ''));
    Ini.WriteString('Binance', 'ApiKeyProd',    GetCfgStr('apiKeyProd', ''));
    Ini.WriteString('Binance', 'SecretKeyProd', GetCfgStr('secretKeyProd', ''));
    Ini.WriteBool  ('Binance', 'Testnet',       GetCfgBool('testnet', True));
    Ini.WriteString('AI',      'ApiKey',        GetCfgStr('aiKey', ''));
    Ini.WriteString('AI',      'Model',         GetCfgStr('aiModel', 'gpt-4o-mini'));
    Ini.WriteBool  ('AI',      'Vision',        GetCfgBool('aiVision', False));
    Ini.WriteString('AI',      'BaseURL',       GetCfgStr('aiBaseURL', ''));
    Ini.WriteString('AI',      'CacheMins',     GetCfgStr('aiCacheMins', '15'));
    Ini.WriteString('AI',      'KeyOpenai',     GetCfgStr('aiKeyOpenai', ''));
    Ini.WriteString('AI',      'KeyGroq',       GetCfgStr('aiKeyGroq', ''));
    Ini.WriteString('AI',      'KeyMistral',    GetCfgStr('aiKeyMistral', ''));
    Ini.WriteString('AI',      'KeyCerebras',   GetCfgStr('aiKeyCerebras', ''));
    Ini.WriteString('AI',      'KeyDeepseek',   GetCfgStr('aiKeyDeepseek', ''));
    Ini.WriteString('Trading', 'Interval',      GetCfgStr('interval', '1h'));
    Ini.WriteString('Trading', 'Amount',        GetCfgStr('tradeAmount', '100'));
    Ini.WriteString('Trading', 'TrailingStop',   GetCfgStr('trailingStop', '3.0'));
    Ini.WriteString('Trading', 'TakeProfit',    GetCfgStr('takeProfit', '8.0'));
    Ini.WriteString('Trading', 'MinConfidence', GetCfgStr('minConfidence', '70'));
    Ini.WriteString('Trading', 'MinScore',      GetCfgStr('minScore', '25'));
    Ini.WriteString('Trading', 'BotInterval',   GetCfgStr('botInterval', '180'));
    Ini.WriteBool  ('Trading', 'AutoTrade',     GetCfgBool('autoTrade', False));
    Ini.WriteString('Trading', 'TopCoins',         GetCfgStr('topCoins', '30'));
    Ini.WriteString('Trading', 'ScanMode',       GetCfgStr('scanMode', 'recovery'));
    Ini.WriteString('Trading', 'RecoveryHours',  GetCfgStr('recoveryHours', '24'));
    Ini.WriteString('Trading', 'LateralTimeout', GetCfgStr('lateralTimeout', '24'));
    Ini.WriteString('Trading', 'TradeCooldown', GetCfgStr('tradeCooldown', '30'));
    Ini.WriteString('Trading', 'SnapshotInterval', GetCfgStr('snapshotInterval', '30'));
    Ini.WriteBool  ('DCA',     'Enabled',          GetCfgBool('dcaEnabled', False));
    Ini.WriteString('DCA',     'Max',              GetCfgStr('dcaMax', '3'));
    Ini.WriteString('DCA',     'Level1',           GetCfgStr('dcaLevel1', '3'));
    Ini.WriteString('DCA',     'Level2',           GetCfgStr('dcaLevel2', '5'));
    Ini.WriteString('DCA',     'Level3',           GetCfgStr('dcaLevel3', '8'));
    Ini.WriteBool  ('Telegram','Enabled',           GetCfgBool('telegramEnabled', False));
    Ini.WriteString('Telegram','Token',             GetCfgStr('telegramToken', ''));
    Ini.WriteString('Telegram','ChatId',            GetCfgStr('telegramChatId', ''));
  finally
    Ini.Free;
  end;
end;

{ ================================================================
  TIMERS
  ================================================================ }

procedure TfrmMain.OnTimerScan(Sender: TObject);
begin
  if FPageReady and not FScanning then DoScan;
end;

procedure TfrmMain.OnTimerPrice(Sender: TObject);
begin
  if FPageReady and (FSelectedSymbol <> '') then UpdatePrice;
end;

procedure TfrmMain.OnTimerWallet(Sender: TObject);
begin
  if FPageReady and not FRefreshingWallet then
  begin
    AddLog('Carteira', 'Snapshot automatico da carteira...');
    DoRefreshWallet;
  end;
end;

procedure TfrmMain.OnTimerBot(Sender: TObject);
begin
  if not FBotRunning then Exit;

  // Protecao SEMPRE ativa, mesmo durante analise da IA
  CheckStopLossTakeProfit;
  CheckDCA;
  CheckLateralPositions;

  // Analise so roda quando nao ha outra em andamento
  if not FBotCycleActive then
  begin
    if not FScanning then
      DoScan;
    if Length(FTopCoins) > 0 then
      DoBotAnalyzeAll;
  end;
end;

procedure TfrmMain.DoBotAnalyzeAll;
var
  LCoins: TCoinRecoveryArray;
  LUseAI: Boolean;
  LInterval: string;
  LMinConf, LStopPct, LTPPct, LCooldownMin, LTradeAmt, LMinScore: Double;
  LAutoTrade: Boolean;
begin
  if FBotCycleActive then Exit;
  FBotCycleActive := True;

  // Captura configs e lista no thread principal
  LCoins := Copy(FTopCoins);
  LUseAI := GetCfgStr('aiKey', '') <> '';
  LInterval := GetInterval;
  LMinConf := GetCfgDbl('minConfidence', 70);
  LMinScore := GetCfgDbl('minScore', 25);
  LStopPct := GetCfgDbl('trailingStop', 3);
  LTPPct := GetCfgDbl('takeProfit', 8);
  LCooldownMin := GetCfgDbl('tradeCooldown', 30);
  LTradeAmt := GetCfgDbl('tradeAmount', 100);
  LAutoTrade := GetCfgBool('autoTrade', False);
  var LCacheMins: Integer := Round(GetCfgDbl('aiCacheMins', 15));

  // IMPORTANTE: injeta moedas com posicao aberta na lista de analise
  // Garante que a IA sempre avalie se deve vender, mesmo se a moeda saiu do scan
  for var PI := 0 to FOpenPositions.Count - 1 do
  begin
    var LPosSymbol := FOpenPositions[PI].Symbol;
    var LFound := False;
    for var CI := 0 to High(LCoins) do
      if LCoins[CI].Symbol = LPosSymbol then
      begin
        LFound := True;
        Break;
      end;
    if not LFound then
    begin
      var LExtra: TCoinRecovery;
      LExtra.Symbol := LPosSymbol;
      LExtra.ScanMetric := 0;
      LCoins := LCoins + [LExtra];
    end;
  end;

  TThread.Queue(nil, procedure
  begin
    AddLog('Bot', Format('=== Ciclo: analisando %d moedas (%d do scan + posicoes abertas) ===',
      [Length(LCoins), Length(FTopCoins)]));
  end);

  TThread.CreateAnonymousThread(procedure
  var
    CI: Integer;
    LSymbol: string;
    LCandles: TCandleArray;
    LIndicators: TTechnicalIndicators;
    LAnalysis: TAIAnalysis;
    LTicker: TJSONObject;
    LPrice24hAgo, LVol24h, LScore: Double;
    LBreakdown: string;
    LHasPos: Boolean;
    LBuyPrice: Double;
    LAISent, LAISkipped: Integer;
    LCanBuy: Boolean;
    LUSDTBalance: Double;
  begin
    LAISent := 0;
    LAISkipped := 0;

    // Verifica saldo USDT antes de iniciar o ciclo
    LCanBuy := True;
    try
      LUSDTBalance := FBinance.GetBalance('USDT').Free;
      if LUSDTBalance < LTradeAmt then
      begin
        LCanBuy := False;
        var LBalMsg := Format('Saldo USDT: %.2f < %.2f (minimo p/ trade) - analisando apenas moedas com posicao aberta',
          [LUSDTBalance, LTradeAmt]);
        TThread.Synchronize(nil, procedure begin AddLog('Bot', LBalMsg); end);
      end;
    except
      on E: Exception do
      begin
        var LBalErr := 'Erro ao consultar saldo USDT: ' + E.Message;
        TThread.Synchronize(nil, procedure begin AddLog('Erro', LBalErr); end);
      end;
    end;

    try
      for CI := 0 to High(LCoins) do
      begin
        if not FBotRunning then Break;

        LSymbol := LCoins[CI].Symbol;

        // 0. Se nao pode comprar, verifica se tem posicao aberta antes de gastar API
        if not LCanBuy then
        begin
          LHasPos := False;
          for var PIdx := 0 to FOpenPositions.Count - 1 do
            if FOpenPositions[PIdx].Symbol = LSymbol then
            begin
              LHasPos := True;
              Break;
            end;
          if not LHasPos then
          begin
            Inc(LAISkipped);
            var LSkipBalMsg := Format('(%d/%d) %s: Sem saldo p/ compra e sem posicao - pulando',
              [CI + 1, Length(LCoins), LSymbol]);
            TThread.Synchronize(nil, procedure begin AddLog('Bot', LSkipBalMsg); end);
            Continue;
          end;
        end;

        // 1. Busca candles
        try
          LCandles := FBinance.GetKlines(LSymbol, LInterval, 100);
        except
          on E: Exception do begin
            var LErrMsg := LSymbol + ': ' + E.Message;
            TThread.Synchronize(nil, procedure begin AddLog('Erro', LErrMsg); end);
            Continue;
          end;
        end;
        if Length(LCandles) = 0 then Continue;

        // 2. Indicadores
        LPrice24hAgo := 0; LVol24h := 0;
        try
          LTicker := FBinance.Get24hTicker(LSymbol);
          try
            if LTicker <> nil then
            begin
              LPrice24hAgo := StrToFloatDef(LTicker.GetValue<string>('prevClosePrice', '0'), 0, FmtDot);
              LVol24h := StrToFloatDef(LTicker.GetValue<string>('quoteVolume', '0'), 0, FmtDot);
            end;
          finally
            LTicker.Free;
          end;
        except end;

        LIndicators := TTechnicalAnalysis.FullAnalysis(LCandles, LPrice24hAgo, LVol24h);

        // 2b. Order Book
        try
          var LOB := FBinance.GetOrderBook(LSymbol, 100);
          LIndicators.OBImbalance := LOB.Imbalance;
          LIndicators.OBSpread := LOB.Spread;
          LIndicators.OBBidTotal := LOB.BidTotal;
          LIndicators.OBAskTotal := LOB.AskTotal;
          LIndicators.OBBigBidWall := LOB.BiggestBidWall;
          LIndicators.OBBigAskWall := LOB.BiggestAskWall;
          LIndicators.OBBigBidPrice := LOB.BiggestBidWallPrice;
          LIndicators.OBBigAskPrice := LOB.BiggestAskWallPrice;
        except end;

        // 3. Verifica posicao para contexto (ANTES do pre-filtro)
        // Agrupa TODAS as posicoes DCA (preco medio ponderado)
        LHasPos := False;
        LBuyPrice := 0;
        var LPosTotalQty: Double := 0;
        var LPosTotalCost: Double := 0;
        for var PIdx := 0 to FOpenPositions.Count - 1 do
          if FOpenPositions[PIdx].Symbol = LSymbol then
          begin
            LHasPos := True;
            LPosTotalQty := LPosTotalQty + FOpenPositions[PIdx].Quantity;
            LPosTotalCost := LPosTotalCost + (FOpenPositions[PIdx].BuyPrice * FOpenPositions[PIdx].Quantity);
          end;
        if LHasPos and (LPosTotalQty > 0) then
          LBuyPrice := LPosTotalCost / LPosTotalQty;

        // 3b. Take Profit automatico: vende TODAS as posicoes se atingiu a meta
        if LHasPos and (LTPPct > 0) and (LBuyPrice > 0) and (LPosTotalQty > 0) then
        begin
          var LCurPrice := LIndicators.CurrentPrice;
          var LGainPct := ((LCurPrice - LBuyPrice) / LBuyPrice) * 100;
          if LGainPct >= LTPPct then
          begin
            var LTPMsg := Format('TAKE PROFIT: %s | Medio: $%s | Ganho: +%.2f%% (meta: %.1f%%) | Vendendo!',
              [LSymbol, FormatFloat('0.####', LBuyPrice, FmtDot), LGainPct, LTPPct]);
            var LTPSellAmt := LPosTotalQty * LCurPrice;
            TThread.Synchronize(nil, procedure
            begin
              AddLog('TakeProfit', LTPMsg);
              var LSaved := FSelectedSymbol;
              FSelectedSymbol := LSymbol;
              FLastIndicators.CurrentPrice := LCurPrice;
              DoSell(LTPSellAmt);
              FLastTradeTime.AddOrSetValue(LSymbol, Now);
              FSelectedSymbol := LSaved;
            end);
            Continue;  // Ja vendeu, pula para proxima moeda
          end;
        end;

        // 4. Score tecnico (rapido, gratuito)
        LScore := TTechnicalAnalysis.TechnicalScoreEx(LIndicators, LBreakdown);

        // Score fraco e sem posicao? Pula direto
        if (Abs(LScore) < LMinScore) and not LHasPos then
        begin
          Inc(LAISkipped);
          var LSkipMsg := Format('(%d/%d) %s: Score %.0f (fraco) - pulando',
            [CI + 1, Length(LCoins), LSymbol, LScore]);
          TThread.Synchronize(nil, procedure begin AddLog('Bot', LSkipMsg); end);
          Continue;
        end;

        // Direcao incompativel com situacao? Pula
        if (LScore > 0) and LHasPos then Continue;     // BUY mas ja tem posicao
        if (LScore < 0) and not LHasPos then Continue;  // SELL mas sem posicao

        // 5. Decide se precisa IA ou score tecnico basta
        // IA e chamada quando o score tecnico passa o minScore configurado:
        //   - Tem posicao + score negativo → IA confirma VENDA
        //   - Sem posicao + score positivo → IA confirma COMPRA
        var LNeedAI := False;
        if LUseAI then
        begin
          if LHasPos and (LScore < -LMinScore) then
            LNeedAI := True   // Posicao em risco, IA confirma venda
          else if (not LHasPos) and (LScore > LMinScore) then
            LNeedAI := True;  // Oportunidade detectada, IA confirma compra
        end;

        if LNeedAI then
        begin
          // Verifica cache de IA antes de chamar API
          var LUsedCache := False;
          if (LCacheMins > 0) then
          begin
            var LCached: TAIAnalysis;
            TThread.Synchronize(nil, procedure
            begin
              if FAICache.TryGetValue(LSymbol, LCached) then
              begin
                if MinutesBetween(Now, LCached.Timestamp) < LCacheMins then
                  LUsedCache := True;
              end;
            end);
            if LUsedCache then
            begin
              LAnalysis := LCached;
              Inc(LAISkipped);
              var LCacheMsg := Format('(%d/%d) %s: IA (cache %dmin) -> %s | Confianca: %.0f%%',
                [CI + 1, Length(LCoins), LSymbol, MinutesBetween(Now, LCached.Timestamp),
                 SignalToStr(LCached.Signal), LCached.Confidence]);
              TThread.Synchronize(nil, procedure begin AddLog('IA', LCacheMsg); end);
            end;
          end;

          if not LUsedCache then
          begin
            Inc(LAISent);
            var LAIMsg := Format('[IA #%d] %s: Confirmando com IA (score %.0f)... (%d/%d)',
              [LAISent, LSymbol, LScore, CI + 1, Length(LCoins)]);
            TThread.Synchronize(nil, procedure begin AddLog('IA', LAIMsg); end);
            var LSW := TStopwatch.StartNew;
            try
              LAnalysis := FAIEngine.AnalyzeMarket(LSymbol, LIndicators, LCandles, LHasPos, LBuyPrice);
            except
              on E: Exception do
              begin
                LSW.Stop;
                var LErrIA := Format('[IA #%d] %s: IA falhou apos %.1fs: %s',
                  [LAISent, LSymbol, LSW.Elapsed.TotalSeconds, E.Message]);
                TThread.Synchronize(nil, procedure begin AddLog('Erro', LErrIA); end);
                Continue;
              end;
            end;
            LSW.Stop;
            var LElapsedMs := LSW.ElapsedMilliseconds;
            var LTkIn := FAIEngine.LastPromptTokens;
            var LTkOut := FAIEngine.LastCompletionTokens;
            var LAIDoneMsg := Format('[IA #%d] %s: Resposta em %.1fs (%d+%d tokens)',
              [LAISent, LSymbol, LElapsedMs / 1000, LTkIn, LTkOut]);
            TThread.Synchronize(nil, procedure
            begin
              AddLog('IA', LAIDoneMsg);
              Inc(FAITotalCalls);
              Inc(FAITotalTokensIn, LTkIn);
              Inc(FAITotalTokensOut, LTkOut);
              Inc(FAITotalTimeMs, LElapsedMs);
              SendAIStats;
              FAICache.AddOrSetValue(LSymbol, LAnalysis);
              try
                FDB.SaveAIAnalysis(LSymbol, LAnalysis);
              except
                on E: Exception do
                  AddLog('Erro', 'SaveAIAnalysis(' + LSymbol + '): ' + E.Message);
              end;
            end);
          end;
        end
        else
        begin
          // Score tecnico decide sozinho (sem gastar IA)
          LAnalysis.Signal := tsHold;
          LAnalysis.Confidence := Abs(LScore);
          if LScore > 60 then LAnalysis.Signal := tsStrongBuy
          else if LScore > 40 then LAnalysis.Signal := tsBuy
          else if LScore < -60 then LAnalysis.Signal := tsStrongSell
          else if LScore < -40 then LAnalysis.Signal := tsSell;
          LAnalysis.Reasoning := 'Score tecnico: ' + LBreakdown;
          LAnalysis.Timestamp := Now;
          LAnalysis.SuggestedEntry := LIndicators.CurrentPrice;
          LAnalysis.SuggestedStopLoss := LIndicators.CurrentPrice * (1 - LStopPct / 100);
          LAnalysis.SuggestedTakeProfit := LIndicators.CurrentPrice * (1 + LTPPct / 100);
        end;

        // Log da analise (NAO altera a moeda selecionada na UI)
        var LLogAnalise := Format('[%d/%d] %s -> %s | Confianca: %.0f%%',
          [CI + 1, Length(LCoins), LSymbol, SignalToStr(LAnalysis.Signal), LAnalysis.Confidence]);
        var LLogMotivo := LAnalysis.Reasoning;
        var LLogTag: string;
        if LNeedAI then LLogTag := 'IA' else LLogTag := 'Bot';
        TThread.Synchronize(nil, procedure
        begin
          AddLog(LLogTag, LLogAnalise);
          AddLog(LLogTag, 'Motivo: ' + LLogMotivo);
        end);

        // 5b. Notifica oportunidades fortes via Telegram (com grafico)
        if (LAnalysis.Signal = tsStrongBuy) and (LAnalysis.Confidence >= LMinConf) and not LHasPos then
        begin
          var LTgOpp := Format(
            '&#x1F50D; <b>OPORTUNIDADE</b> %s'#10 +
            'Sinal: %s | Confianca: %.0f%%'#10 +
            'Preco: $%s'#10 +
            '%s',
            [LSymbol, SignalToStr(LAnalysis.Signal), LAnalysis.Confidence,
             FormatFloat('0.####', LIndicators.CurrentPrice, FmtDot),
             LAnalysis.Reasoning]);
          var LChartB64 := '';
          try LChartB64 := FAIEngine.GenerateChartBase64(LCandles); except end;
          TThread.Synchronize(nil, procedure begin SendTelegramPhoto(LTgOpp, LChartB64); end);
        end;

        // 6. Auto-trade
        if LAutoTrade and FBotRunning and (LAnalysis.Confidence >= LMinConf) then
        begin
          // Blacklist: symbol vendido por lateralizacao?
          var LBlacklistTime: TDateTime;
          var LIsBlacklisted := False;
          TThread.Synchronize(nil, procedure
          begin
            if FLateralBlacklist.TryGetValue(LSymbol, LBlacklistTime) then
              LIsBlacklisted := True;
          end);

          if LIsBlacklisted then
          begin
            var LBlkMsg := Format('%s: BLOQUEADO (vendido por lateralizacao, aguardando expirar)', [LSymbol]);
            TThread.Synchronize(nil, procedure begin AddLog('Bot', LBlkMsg); end);
          end
          else
          begin
            // Cooldown
            var LLastTime: TDateTime;
            var LInCooldown := False;
            TThread.Synchronize(nil, procedure
            begin
              if FLastTradeTime.TryGetValue(LSymbol, LLastTime) then
              begin
                var LElapsed := MinutesBetween(Now, LLastTime) + (SecondsBetween(Now, LLastTime) mod 60) / 60.0;
                if LElapsed < LCooldownMin then
                begin
                  LInCooldown := True;
                  AddLog('Bot', Format('%s: Cooldown ativo (%.0f/%.0f min)',
                    [LSymbol, LElapsed, LCooldownMin]));
                end;
              end;
            end);

            if not LInCooldown then
            begin
              if (LAnalysis.Signal in [tsStrongBuy, tsBuy]) and not LHasPos then
              begin
                var LBuyMsg := Format('AUTO-COMPRA %s | Confianca: %.0f%% | %s', [LSymbol, LAnalysis.Confidence, LAnalysis.Reasoning]);
                var LBuyChart := '';
                try LBuyChart := FAIEngine.GenerateChartBase64(LCandles); except end;
                TThread.Synchronize(nil, procedure
                var LSaved: string;
                begin
                  LSaved := FSelectedSymbol;
                  FSelectedSymbol := LSymbol;
                  FLastIndicators.CurrentPrice := LIndicators.CurrentPrice;
                  FLastAnalysis := LAnalysis;  // Salva analise para o trade registrar o sinal correto
                  AddLog('Trade', LBuyMsg);
                  DoBuy(LTradeAmt);
                  FLastTradeTime.AddOrSetValue(LSymbol, Now);
                  FSelectedSymbol := LSaved;
                  SendTelegramPhoto(
                    '&#x2705; <b>AUTO-COMPRA</b> ' + LSymbol + #10 +
                    'Confianca: ' + FormatFloat('0', LAnalysis.Confidence) + '%' + #10 +
                    LAnalysis.Reasoning, LBuyChart);
                end);
                Sleep(2000);
              end
              else if (LAnalysis.Signal in [tsStrongSell, tsSell]) and LHasPos then
              begin
                var LSellMsg := Format('AUTO-VENDA %s | Confianca: %.0f%% | %s', [LSymbol, LAnalysis.Confidence, LAnalysis.Reasoning]);
                var LSellChart := '';
                try LSellChart := FAIEngine.GenerateChartBase64(LCandles); except end;
                TThread.Synchronize(nil, procedure
                var LSaved: string;
                begin
                  LSaved := FSelectedSymbol;
                  FSelectedSymbol := LSymbol;
                  FLastIndicators.CurrentPrice := LIndicators.CurrentPrice;
                  FLastAnalysis := LAnalysis;  // Salva analise para o trade registrar o sinal correto
                  AddLog('Trade', LSellMsg);
                  DoSell(0);  // 0 = vende todas as posicoes rastreadas
                  FLastTradeTime.AddOrSetValue(LSymbol, Now);
                  FSelectedSymbol := LSaved;
                  SendTelegramPhoto(
                    '&#x1F534; <b>AUTO-VENDA</b> ' + LSymbol + #10 +
                    'Confianca: ' + FormatFloat('0', LAnalysis.Confidence) + '%' + #10 +
                    LAnalysis.Reasoning, LSellChart);
                end);
                Sleep(2000);
              end;
            end;
          end;
        end;

        Sleep(200); // Pequeno delay entre moedas para nao bater rate limit
      end;

      var LSummary := Format('=== Ciclo completo: %d moedas, %d enviadas p/ IA, %d puladas/cache ===',
        [Length(LCoins), LAISent, LAISkipped]);
      TThread.Synchronize(nil, procedure
      begin
        AddLog('Bot', LSummary);
      end);
    except
      on E: Exception do
      begin
        var LErrMsg := 'Ciclo bot: ' + E.Message;
        TThread.Synchronize(nil, procedure
        begin
          AddLog('Erro', LErrMsg);
        end);
      end;
    end;
    // SEMPRE reseta FBotCycleActive, mesmo em caso de crash
    TThread.Queue(nil, procedure
    begin
      FBotCycleActive := False;
    end);
  end).Start;
end;

{ ================================================================
  GENETIC ALGORITHM OPTIMIZER
  ================================================================ }

procedure TfrmMain.DoTestAI(Data: TJSONObject);
var
  LKey, LModel, LURL: string;
begin
  if Data = nil then Exit;
  LKey := Data.GetValue<string>('aiKey', '');
  LModel := Data.GetValue<string>('aiModel', 'gpt-4o-mini');
  LURL := Data.GetValue<string>('aiBaseURL', 'https://api.openai.com/v1');
  if LURL = '' then LURL := 'https://api.openai.com/v1';

  AddLog('IA', Format('Testando: %s em %s ...', [LModel, LURL]));

  TThread.CreateAnonymousThread(procedure
  var
    LHttp: THTTPClient;
    LResp: IHTTPResponse;
    LReq, LMsg: TJSONObject;
    LMsgs: TJSONArray;
    LSrc: TStringStream;
    LResult, LContent: string;
    LSuccess: Boolean;
    LT0: TDateTime;
  begin
    LHttp := THTTPClient.Create;
    try
      LHttp.ConnectionTimeout := 10000;
      LHttp.ResponseTimeout := 30000;

      LReq := TJSONObject.Create;
      try
        LReq.AddPair('model', LModel);
        LReq.AddPair('max_tokens', TJSONNumber.Create(50));
        LReq.AddPair('temperature', TJSONNumber.Create(0));
        LMsgs := TJSONArray.Create;
        LMsg := TJSONObject.Create;
        LMsg.AddPair('role', 'user');
        LMsg.AddPair('content', 'Responda apenas: OK');
        LMsgs.AddElement(LMsg);
        LReq.AddPair('messages', LMsgs);

        LSrc := TStringStream.Create(LReq.ToJSON, TEncoding.UTF8);
        try
          LHttp.CustomHeaders['Authorization'] := 'Bearer ' + LKey;
          LHttp.CustomHeaders['Content-Type'] := 'application/json';

          LT0 := Now;
          LSuccess := False;
          LResult := '';

          try
            LResp := LHttp.Post(LURL + '/chat/completions', LSrc, nil,
              [TNameValuePair.Create('Content-Type','application/json')]);

            var LElapsed := FormatFloat('0.1', SecondSpan(Now, LT0));

            if LResp.StatusCode = 200 then
            begin
              // Try to extract content
              LContent := '';
              try
                var RJ := TJSONObject.ParseJSONValue(LResp.ContentAsString(TEncoding.UTF8));
                if RJ <> nil then
                try
                  var Ch := TJSONObject(RJ).GetValue<TJSONArray>('choices');
                  if (Ch <> nil) and (Ch.Count > 0) then
                    LContent := TJSONObject(Ch.Items[0]).GetValue<TJSONObject>('message').GetValue<string>('content');
                finally
                  RJ.Free;
                end;
              except end;

              LSuccess := True;
              LResult := Format('Modelo respondeu em %ss: "%s"', [LElapsed, Copy(LContent, 1, 80)]);
            end
            else
            begin
              LResult := Format('HTTP %d em %ss', [LResp.StatusCode, LElapsed]);
              try
                LResult := LResult + ' - ' + Copy(LResp.ContentAsString(TEncoding.UTF8), 1, 200);
              except end;
            end;
          except
            on E: Exception do
              LResult := Format('Erro em %ss: %s',
                [FormatFloat('0.1', SecondSpan(Now, LT0)), E.Message]);
          end;

          TThread.Synchronize(nil, procedure
          begin
            AddLog('IA', 'Teste: ' + LResult);
            var DR := TJSONObject.Create;
            DR.AddPair('success', TJSONBool.Create(LSuccess));
            DR.AddPair('message', LResult);
            SendToJS('testAIResult', DR);
          end);
        finally LSrc.Free; end;
      finally LReq.Free; end;
    finally LHttp.Free; end;
  end).Start;
end;

procedure TfrmMain.DoOptimize;
var
  LCoins: TCoinRecoveryArray;
  LInterval: string;
  LNumCoins: Integer;
begin
  if FOptimizing then
  begin
    AddLog('GA', 'Otimizacao ja em andamento...');
    Exit;
  end;

  if Length(FTopCoins) = 0 then
  begin
    AddLog('GA', 'Faca um scan primeiro para ter moedas disponiveis.');
    var DE := TJSONObject.Create;
    DE.AddPair('status', 'error');
    DE.AddPair('message', 'Faca um scan primeiro.');
    SendToJS('optimizeProgress', DE);
    Exit;
  end;

  FOptimizing := True;
  LCoins := Copy(FTopCoins);
  LInterval := GetInterval;
  LNumCoins := Min(15, Length(LCoins));

  var DStart := TJSONObject.Create;
  DStart.AddPair('status', 'fetching');
  DStart.AddPair('message', 'Buscando dados historicos...');
  DStart.AddPair('progress', TJSONNumber.Create(0));
  SendToJS('optimizeProgress', DStart);
  AddLog('GA', Format('Iniciando otimizacao GA com %d moedas...', [LNumCoins]));

  TThread.CreateAnonymousThread(procedure
  var
    LSymbols: TArray<string>;
    LCandleData: TArray<TCandleArray>;
    I: Integer;
    LCandles: TCandleArray;
    LGA: TGeneticOptimizer;
  begin
    try
      // Phase 1: Fetch candle data
      SetLength(LSymbols, 0);
      SetLength(LCandleData, 0);

      for I := 0 to LNumCoins - 1 do
      begin
        var LProg := Format('Buscando candles: %d/%d (%s)',
          [I + 1, LNumCoins, LCoins[I].Symbol]);
        var LPct := (I + 1) / LNumCoins * 10;
        TThread.Synchronize(nil, procedure
        begin
          var DP := TJSONObject.Create;
          DP.AddPair('status', 'fetching');
          DP.AddPair('message', LProg);
          DP.AddPair('progress', TJSONNumber.Create(LPct));
          SendToJS('optimizeProgress', DP);
        end);

        try
          LCandles := FBinance.GetKlines(LCoins[I].Symbol, LInterval, 500);
          if Length(LCandles) >= 100 then
          begin
            SetLength(LSymbols, Length(LSymbols) + 1);
            LSymbols[High(LSymbols)] := LCoins[I].Symbol;
            SetLength(LCandleData, Length(LCandleData) + 1);
            LCandleData[High(LCandleData)] := LCandles;
          end;
        except end;
        Sleep(200);
      end;

      if Length(LSymbols) < 3 then
      begin
        TThread.Synchronize(nil, procedure
        begin
          AddLog('GA', 'Dados insuficientes (< 3 moedas com candles validos).');
          FOptimizing := False;
          var DE := TJSONObject.Create;
          DE.AddPair('status', 'error');
          DE.AddPair('message', 'Dados insuficientes (< 3 moedas).');
          SendToJS('optimizeProgress', DE);
        end);
        Exit;
      end;

      // Phase 2: Pre-compute + GA
      TThread.Synchronize(nil, procedure
      begin
        var DP := TJSONObject.Create;
        DP.AddPair('status', 'running');
        DP.AddPair('message', Format('Pre-computando indicadores para %d moedas...', [Length(LSymbols)]));
        DP.AddPair('progress', TJSONNumber.Create(10));
        SendToJS('optimizeProgress', DP);
      end);

      LGA := TGeneticOptimizer.Create;
      try
        FOptimizer := LGA;
        LGA.PopulationSize := 100;
        LGA.Generations := 50;
        LGA.MutationRate := 0.15;
        LGA.ElitismPercent := 0.05;

        LGA.OnProgress := procedure(Gen, TotalGen: Integer; BestFit: Double; BestRes: TBacktestResult)
        begin
          TThread.Synchronize(nil, procedure
          begin
            var DP := TJSONObject.Create;
            DP.AddPair('status', 'running');
            DP.AddPair('generation', TJSONNumber.Create(Gen));
            DP.AddPair('totalGenerations', TJSONNumber.Create(TotalGen));
            DP.AddPair('bestFitness', TJSONNumber.Create(BestFit));
            DP.AddPair('bestProfit', TJSONNumber.Create(BestRes.NetProfit));
            DP.AddPair('progress', TJSONNumber.Create(10 + (Gen / TotalGen) * 90));
            DP.AddPair('message', Format('Geracao %d/%d | Lucro: %.2f%% | Fitness: %.1f',
              [Gen, TotalGen, BestRes.NetProfit, BestFit]));
            SendToJS('optimizeProgress', DP);
          end);
        end;

        LGA.RunOptimization(LSymbols, LCandleData);

        if not LGA.Cancelled then
        begin
          TThread.Synchronize(nil, procedure
          var DR: TJSONObject;
          begin
            DR := TJSONObject.Create;
            DR.AddPair('status', 'complete');
            DR.AddPair('wRSI', TJSONNumber.Create(LGA.BestParams.wRSI));
            DR.AddPair('wMACDHist', TJSONNumber.Create(LGA.BestParams.wMACDHist));
            DR.AddPair('wMACDSignal', TJSONNumber.Create(LGA.BestParams.wMACDSignal));
            DR.AddPair('wPriceSMA', TJSONNumber.Create(LGA.BestParams.wPriceSMA));
            DR.AddPair('wSMATrend', TJSONNumber.Create(LGA.BestParams.wSMATrend));
            DR.AddPair('wBollinger', TJSONNumber.Create(LGA.BestParams.wBollinger));
            DR.AddPair('stopLoss', TJSONNumber.Create(LGA.BestParams.StopLoss));
            DR.AddPair('takeProfit', TJSONNumber.Create(LGA.BestParams.TakeProfit));
            DR.AddPair('minScore', TJSONNumber.Create(LGA.BestParams.MinScore));
            DR.AddPair('rsiOversold', TJSONNumber.Create(LGA.BestParams.RSIOversold));
            DR.AddPair('rsiOverbought', TJSONNumber.Create(LGA.BestParams.RSIOverbought));
            DR.AddPair('netProfit', TJSONNumber.Create(LGA.BestResult.NetProfit));
            DR.AddPair('numTrades', TJSONNumber.Create(LGA.BestResult.NumTrades));
            DR.AddPair('maxDrawdown', TJSONNumber.Create(LGA.BestResult.MaxDrawdown));
            DR.AddPair('winRate', TJSONNumber.Create(LGA.BestResult.WinRate));
            DR.AddPair('fitness', TJSONNumber.Create(LGA.BestFitness));
            DR.AddPair('symbolsUsed', TJSONNumber.Create(Length(LSymbols)));
            SendToJS('optimizeResult', DR);
            AddLog('GA', Format('Otimizacao concluida! Lucro: %.2f%% | Trades: %d | DrawDown: %.2f%% | WinRate: %.1f%%',
              [LGA.BestResult.NetProfit, LGA.BestResult.NumTrades, LGA.BestResult.MaxDrawdown, LGA.BestResult.WinRate]));
            FOptimizing := False;
          end);
        end
        else
        begin
          TThread.Synchronize(nil, procedure
          begin
            AddLog('GA', 'Otimizacao cancelada.');
            FOptimizing := False;
            var DC := TJSONObject.Create;
            DC.AddPair('status', 'cancelled');
            DC.AddPair('message', 'Cancelado pelo usuario.');
            SendToJS('optimizeProgress', DC);
          end);
        end;
      finally
        FOptimizer := nil;
        LGA.Free;
      end;
    except
      on E: Exception do
        TThread.Synchronize(nil, procedure
        begin
          AddLog('Erro', 'GA: ' + E.Message);
          FOptimizing := False;
          var DE := TJSONObject.Create;
          DE.AddPair('status', 'error');
          DE.AddPair('message', 'Erro: ' + E.Message);
          SendToJS('optimizeProgress', DE);
        end);
    end;
  end).Start;
end;

procedure TfrmMain.DoCancelOptimize;
begin
  if (FOptimizer <> nil) then
  begin
    FOptimizer.Cancel;
    AddLog('GA', 'Cancelamento solicitado...');
  end;
end;

procedure TfrmMain.DoApplyOptimizedParams(Data: TJSONObject);
begin
  if Data = nil then Exit;

  // Update config with optimized trading parameters
  var LNewConfig := FConfig.Clone as TJSONObject;
  try
    LNewConfig.RemovePair('trailingStop');
    LNewConfig.AddPair('trailingStop',
      FormatFloat('0.0', Data.GetValue<Double>('stopLoss', 3), FmtDot));

    LNewConfig.RemovePair('takeProfit');
    LNewConfig.AddPair('takeProfit',
      FormatFloat('0.0', Data.GetValue<Double>('takeProfit', 8), FmtDot));

    LNewConfig.RemovePair('minScore');
    LNewConfig.AddPair('minScore',
      IntToStr(Round(Data.GetValue<Double>('minScore', 25))));

    FreeAndNil(FConfig);
    FConfig := LNewConfig;
    LNewConfig := nil;

    SaveConfig;
    AddLog('GA', Format('Parametros aplicados: TS=%.1f%% TP=%.1f%% MinScore=%.0f',
      [GetCfgDbl('trailingStop', 3), GetCfgDbl('takeProfit', 8), GetCfgDbl('minScore', 25)]));

    var DApplied := TJSONObject.Create;
    DApplied.AddPair('trailingStop', GetCfgStr('trailingStop', '3.0'));
    DApplied.AddPair('takeProfit', GetCfgStr('takeProfit', '8.0'));
    DApplied.AddPair('minScore', GetCfgStr('minScore', '25'));
    SendToJS('optimizeApplied', DApplied);
  except
    LNewConfig.Free;
    raise;
  end;
end;

procedure TfrmMain.CheckLateralPositions;
var
  I, J: Integer;
  LSymbol: string;
  LHoursFirst, LTimeout, LPriceChange: Double;
  LCurrentPrice, LAvgPrice, LTotalQty, LTotalCost: Double;
  LSavedSymbol: string;
  LSavedSignal: TTradeSignal;
  LFirstEntry, LEarliestBuy: TDateTime;
  LProcessed: TList<string>;
begin
  if FOpenPositions.Count = 0 then Exit;
  LTimeout := GetCfgDbl('lateralTimeout', 24);
  if LTimeout <= 0 then Exit;

  // Limpa blacklist expirada (2x timeout)
  var LBlacklistKeys := TList<string>.Create;
  try
    for var Pair in FLateralBlacklist do
      if HoursBetween(Now, Pair.Value) >= LTimeout * 2 then
        LBlacklistKeys.Add(Pair.Key);
    for var Key in LBlacklistKeys do
      FLateralBlacklist.Remove(Key);
  finally
    LBlacklistKeys.Free;
  end;

  LProcessed := TList<string>.Create;
  try
    for I := 0 to FOpenPositions.Count - 1 do
    begin
      LSymbol := FOpenPositions[I].Symbol;
      if LProcessed.Contains(LSymbol) then Continue;
      LProcessed.Add(LSymbol);

      // Agrupa todas as posicoes do symbol: preco medio ponderado
      LTotalQty := 0;
      LTotalCost := 0;
      LEarliestBuy := Now;
      for J := 0 to FOpenPositions.Count - 1 do
        if FOpenPositions[J].Symbol = LSymbol then
        begin
          LTotalQty := LTotalQty + FOpenPositions[J].Quantity;
          LTotalCost := LTotalCost + (FOpenPositions[J].BuyPrice * FOpenPositions[J].Quantity);
          if FOpenPositions[J].BuyTime < LEarliestBuy then
            LEarliestBuy := FOpenPositions[J].BuyTime;
        end;

      if LTotalQty <= 0 then Continue;
      LAvgPrice := LTotalCost / LTotalQty;

      // Usa o FirstEntry (sobrevive ciclos compra/venda) ou BuyTime como fallback
      if FSymbolFirstEntry.TryGetValue(LSymbol, LFirstEntry) then
        LHoursFirst := MinutesBetween(Now, LFirstEntry) / 60.0
      else
      begin
        LHoursFirst := MinutesBetween(Now, LEarliestBuy) / 60.0;
        FSymbolFirstEntry.AddOrSetValue(LSymbol, LEarliestBuy);
      end;

      if LHoursFirst >= LTimeout then
      begin
        try
          LCurrentPrice := FBinance.GetPrice(LSymbol);
        except
          Continue;
        end;

        if (LCurrentPrice <= 0) or (LAvgPrice <= 0) then Continue;

        LPriceChange := Abs((LCurrentPrice - LAvgPrice) / LAvgPrice) * 100;

        // Se variacao < 3%, esta lateral
        if LPriceChange < 3.0 then
        begin
          AddLog('Lateral', Format(
            'LATERALIZACAO DETECTADA: %s | %.1fh atras | Medio: $%s | Atual: $%s | Variacao: %.2f%%',
            [LSymbol, LHoursFirst,
             FormatFloat('0.########', LAvgPrice, FmtDot),
             FormatFloat('0.########', LCurrentPrice, FmtDot),
             LPriceChange], FmtDot));
          AddLog('Lateral', Format(
            'Vendendo %s automaticamente (lateral > %.0fh com variacao < 3%%) + BLOQUEIO de recompra por %.0fh',
            [LSymbol, LTimeout, LTimeout * 2], FmtDot));

          FLateralBlacklist.AddOrSetValue(LSymbol, Now);
          FSymbolFirstEntry.Remove(LSymbol);

          LSavedSymbol := FSelectedSymbol;
          LSavedSignal := FLastAutoTradeSignal;

          FSelectedSymbol := LSymbol;
          FLastIndicators.CurrentPrice := LCurrentPrice;
          DoSell(LTotalQty * LCurrentPrice);

          FSelectedSymbol := LSavedSymbol;
          FLastAutoTradeSignal := LSavedSignal;

          Break; // Processa uma por ciclo para nao sobrecarregar
        end
        else
          AddLog('Posicao', Format('%s: %.1fh desde primeiro entry, variacao %.2f%% (nao lateral)',
            [LSymbol, LHoursFirst, LPriceChange], FmtDot));
      end;
    end;
  finally
    LProcessed.Free;
  end;
end;

procedure TfrmMain.CheckStopLossTakeProfit;
const
  FEE_PCT = 0.2; // Taxa round-trip Binance (0.1% compra + 0.1% venda)
var
  I, J: Integer;
  LTrailingPct, LTakeProfit: Double;
  LCurrentPrice: Double;
  LSavedSymbol: string;
  // Agrupamento por symbol
  LSymbol: string;
  LAvgPrice, LTotalQty, LTotalCost, LHighestPrice: Double;
  LEarliestBuy: TDateTime;
  LProcessed: TList<string>;
  LChangePercent, LNetChange, LDropFromPeak: Double;
begin
  if FOpenPositions.Count = 0 then Exit;
  if not FBotRunning then Exit;

  LTrailingPct := GetCfgDbl('trailingStop', 3);
  LTakeProfit := GetCfgDbl('takeProfit', 8);
  if (LTrailingPct <= 0) and (LTakeProfit <= 0) then Exit;

  LProcessed := TList<string>.Create;
  try
    for I := 0 to FOpenPositions.Count - 1 do
    begin
      LSymbol := FOpenPositions[I].Symbol;
      if FOpenPositions[I].BuyPrice <= 0 then Continue;
      if LProcessed.Contains(LSymbol) then Continue;
      LProcessed.Add(LSymbol);

      // Agrupa todas as posicoes do symbol (DCA): preco medio ponderado
      LTotalQty := 0;
      LTotalCost := 0;
      LHighestPrice := 0;
      LEarliestBuy := Now;
      for J := 0 to FOpenPositions.Count - 1 do
        if FOpenPositions[J].Symbol = LSymbol then
        begin
          LTotalQty := LTotalQty + FOpenPositions[J].Quantity;
          LTotalCost := LTotalCost + (FOpenPositions[J].BuyPrice * FOpenPositions[J].Quantity);
          if FOpenPositions[J].HighestPrice > LHighestPrice then
            LHighestPrice := FOpenPositions[J].HighestPrice;
          if FOpenPositions[J].BuyTime < LEarliestBuy then
            LEarliestBuy := FOpenPositions[J].BuyTime;
        end;

      if LTotalQty <= 0 then Continue;
      LAvgPrice := LTotalCost / LTotalQty;

      try
        LCurrentPrice := FBinance.GetPrice(LSymbol);
      except
        Continue;
      end;
      if LCurrentPrice <= 0 then Continue;

      // Atualiza HighestPrice em todas as posicoes do symbol
      if LCurrentPrice > LHighestPrice then
      begin
        LHighestPrice := LCurrentPrice;
        for J := 0 to FOpenPositions.Count - 1 do
          if (FOpenPositions[J].Symbol = LSymbol) and (LCurrentPrice > FOpenPositions[J].HighestPrice) then
          begin
            var LPos := FOpenPositions[J];
            LPos.HighestPrice := LCurrentPrice;
            FOpenPositions[J] := LPos;
          end;
        try FDB.UpdatePositionHighPrice(LSymbol, LCurrentPrice); except end;
      end;

      LChangePercent := ((LCurrentPrice - LAvgPrice) / LAvgPrice) * 100;
      LNetChange := LChangePercent - FEE_PCT;
      LDropFromPeak := ((LHighestPrice - LCurrentPrice) / LHighestPrice) * 100;

      // Trailing Stop: queda do pico >= trailing% (delay 5 min da compra mais antiga)
      if (LTrailingPct > 0) and (LDropFromPeak >= LTrailingPct)
        and (MinutesBetween(Now, LEarliestBuy) >= 5) then
      begin
        AddLog('TrailingStop', Format(
          'TRAILING STOP: %s | Medio: $%s | Pico: $%s | Atual: $%s | Queda: -%.2f%% | P&L: %.2f%%',
          [LSymbol,
           FormatFloat('0.########', LAvgPrice, FmtDot),
           FormatFloat('0.########', LHighestPrice, FmtDot),
           FormatFloat('0.########', LCurrentPrice, FmtDot),
           LDropFromPeak, LNetChange], FmtDot));
        var LTSCaption := Format(
          '&#x26A0; <b>TRAILING STOP</b> %s'#10 +
          'Medio: $%s | Pico: $%s'#10 +
          'Atual: $%s'#10 +
          'Queda: -%.2f%% | P&L: %.2f%%',
          [LSymbol,
           FormatFloat('0.####', LAvgPrice, FmtDot),
           FormatFloat('0.####', LHighestPrice, FmtDot),
           FormatFloat('0.####', LCurrentPrice, FmtDot),
           LDropFromPeak, LNetChange], FmtDot);
        SendTelegramWithChart(LTSCaption, LSymbol);

        LSavedSymbol := FSelectedSymbol;
        FSelectedSymbol := LSymbol;
        FLastIndicators.CurrentPrice := LCurrentPrice;
        DoSell(LTotalQty * LCurrentPrice);
        FSelectedSymbol := LSavedSymbol;
        FLastTradeTime.AddOrSetValue(LSymbol, Now);
      end
      // Take Profit: lucro liquido >= takeProfit%
      else if (LTakeProfit > 0) and (LNetChange >= LTakeProfit) then
      begin
        AddLog('TakeProfit', Format(
          'TAKE PROFIT: %s | Medio: $%s | Pico: $%s | Atual: $%s | P&L: +%.2f%% (liq: +%.2f%%)',
          [LSymbol,
           FormatFloat('0.########', LAvgPrice, FmtDot),
           FormatFloat('0.########', LHighestPrice, FmtDot),
           FormatFloat('0.########', LCurrentPrice, FmtDot),
           LChangePercent, LNetChange], FmtDot));
        var LTPCaption := Format(
          '&#x1F4B0; <b>TAKE PROFIT</b> %s'#10 +
          'Medio: $%s | Atual: $%s'#10 +
          'P&L: +%.2f%% (liq: +%.2f%%)',
          [LSymbol,
           FormatFloat('0.####', LAvgPrice, FmtDot),
           FormatFloat('0.####', LCurrentPrice, FmtDot),
           LChangePercent, LNetChange], FmtDot);
        SendTelegramWithChart(LTPCaption, LSymbol);

        LSavedSymbol := FSelectedSymbol;
        FSelectedSymbol := LSymbol;
        FLastIndicators.CurrentPrice := LCurrentPrice;
        DoSell(LTotalQty * LCurrentPrice);
        FSelectedSymbol := LSavedSymbol;
        FLastTradeTime.AddOrSetValue(LSymbol, Now);
      end;
    end;
  finally
    LProcessed.Free;
  end;
end;

procedure TfrmMain.CheckDCA;
var
  I, J: Integer;
  LSymbol: string;
  LFirstPrice, LCurrentPrice, LDropPct: Double;
  LPosCount: Integer;
  LTradeAmt: Double;
  LMaxDCA: Integer;
  LLevels: array[0..2] of Double;
  LProcessed: TList<string>;
  LSavedSymbol: string;
  LUSDTBal: Double;
begin
  if FOpenPositions.Count = 0 then Exit;
  if not FBotRunning then Exit;
  if not GetCfgBool('dcaEnabled', False) then Exit;

  LTradeAmt := GetCfgDbl('tradeAmount', 100);
  LMaxDCA := Round(GetCfgDbl('dcaMax', 3));
  if LMaxDCA < 1 then LMaxDCA := 1;
  if LMaxDCA > 3 then LMaxDCA := 3;
  LLevels[0] := GetCfgDbl('dcaLevel1', 3);
  LLevels[1] := GetCfgDbl('dcaLevel2', 5);
  LLevels[2] := GetCfgDbl('dcaLevel3', 8);

  // Verifica saldo USDT
  try
    LUSDTBal := FBinance.GetBalance('USDT').Free;
  except
    Exit;
  end;
  if LUSDTBal < LTradeAmt then Exit;

  LProcessed := TList<string>.Create;
  try
    for I := 0 to FOpenPositions.Count - 1 do
    begin
      LSymbol := FOpenPositions[I].Symbol;
      if LProcessed.Contains(LSymbol) then Continue;
      LProcessed.Add(LSymbol);

      // Conta posicoes e pega preco da primeira compra (mais antiga)
      LPosCount := 0;
      LFirstPrice := 0;
      var LEarliestTime: TDateTime := EncodeDate(9999,12,31);
      for J := 0 to FOpenPositions.Count - 1 do
        if FOpenPositions[J].Symbol = LSymbol then
        begin
          Inc(LPosCount);
          if FOpenPositions[J].BuyTime < LEarliestTime then
          begin
            LEarliestTime := FOpenPositions[J].BuyTime;
            LFirstPrice := FOpenPositions[J].BuyPrice;
          end;
        end;

      if LFirstPrice <= 0 then Continue;

      // Ja atingiu maximo de DCAs? (posCount = 1 original + N DCAs)
      var LDCAsDone := LPosCount - 1;
      if LDCAsDone >= LMaxDCA then Continue;

      // Proximo nivel de DCA
      var LNextLevel := LLevels[LDCAsDone]; // 0-based: DCA#1=level[0], DCA#2=level[1]...

      try
        LCurrentPrice := FBinance.GetPrice(LSymbol);
      except
        Continue;
      end;
      if LCurrentPrice <= 0 then Continue;

      LDropPct := ((LFirstPrice - LCurrentPrice) / LFirstPrice) * 100;

      if LDropPct >= LNextLevel then
      begin
        // Cooldown: nao fazer DCA se fez trade recente
        var LLastTime: TDateTime;
        if FLastTradeTime.TryGetValue(LSymbol, LLastTime) then
          if MinutesBetween(Now, LLastTime) < 5 then Continue;

        AddLog('DCA', Format(
          'DCA #%d: %s | Entry: $%s | Atual: $%s | Queda: -%.2f%% (nivel: -%.1f%%)',
          [LDCAsDone + 1, LSymbol,
           FormatFloat('0.########', LFirstPrice, FmtDot),
           FormatFloat('0.########', LCurrentPrice, FmtDot),
           LDropPct, LNextLevel], FmtDot));
        SendTelegram(Format(
          '&#x1F504; <b>DCA #%d</b> %s'#10 +
          'Entry: $%s | Atual: $%s'#10 +
          'Queda: -%.2f%% (nivel: -%.1f%%)',
          [LDCAsDone + 1, LSymbol,
           FormatFloat('0.####', LFirstPrice, FmtDot),
           FormatFloat('0.####', LCurrentPrice, FmtDot),
           LDropPct, LNextLevel], FmtDot));

        LSavedSymbol := FSelectedSymbol;
        FSelectedSymbol := LSymbol;
        FLastIndicators.CurrentPrice := LCurrentPrice;
        DoBuy(LTradeAmt);
        FSelectedSymbol := LSavedSymbol;
        FLastTradeTime.AddOrSetValue(LSymbol, Now);
        Break; // Um DCA por ciclo
      end;
    end;
  finally
    LProcessed.Free;
  end;
end;

end.
