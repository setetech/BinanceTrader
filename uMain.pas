unit uMain;

interface

uses
  Winapi.Windows, Winapi.Messages, System.SysUtils, System.Variants,
  System.Classes, System.UITypes, System.DateUtils, System.Math,
  System.JSON, System.IniFiles, System.IOUtils,
  Vcl.Graphics, Vcl.Controls, Vcl.Forms, Vcl.Dialogs, Vcl.ExtCtrls,
  Vcl.StdCtrls, Vcl.Edge, WebView2, ActiveX,
  System.Generics.Collections, System.Generics.Defaults,
  uTypes, uBinanceAPI, uTechnicalAnalysis, uAIEngine, uDatabase, UniProvider, SQLiteUniProvider, Data.DB, DBAccess, Uni;

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
    FAnalyzing: Boolean;
    FScanning: Boolean;
    FHtmlFilePath: string;

    FTopCoins: TCoinRecoveryArray;
    FSelectedSymbol: string;
    FBotCoinIndex: Integer;  // Indice de rotacao do bot pelas top coins
    FLastAutoTradeSignal: TTradeSignal;  // Evita trades repetidos no mesmo sinal
    FLastTradeTime: TDictionary<string, TDateTime>;  // Cooldown entre trades por symbol
    FRefreshingWallet: Boolean;
    FApiKeyValid: Boolean;
    FOpenPositions: TList<TOpenPosition>;
    FLastCandles: TCandleArray;
    FLastIndicators: TTechnicalIndicators;
    FLastAnalysis: TAIAnalysis;

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
    procedure DoBotAnalyzeAll;

    // Updates
    procedure UpdatePrice;
    procedure UpdateBalance;
    procedure SendTopCoins;
    procedure SendCandles;
    procedure SendIndicators;
    procedure SendSignal;

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
  FScanning := False;
  FLastAutoTradeSignal := tsHold;
  FBotCoinIndex := 0;
  FApiKeyValid := False;
  FSelectedSymbol := '';
  FConfig := TJSONObject.Create;
  FOpenPositions := TList<TOpenPosition>.Create;
  FLastTradeTime := TDictionary<string, TDateTime>.Create;


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
  else if Action = 'refreshWallet' then DoRefreshWallet;
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

  // Envia config
  LCfg := TJSONObject.Create;
  LCfg.AddPair('apiKeyTest',    GetCfgStr('apiKeyTest', ''));
  LCfg.AddPair('secretKeyTest', GetCfgStr('secretKeyTest', ''));
  LCfg.AddPair('apiKeyProd',    GetCfgStr('apiKeyProd', ''));
  LCfg.AddPair('secretKeyProd', GetCfgStr('secretKeyProd', ''));
  LCfg.AddPair('testnet',      TJSONBool.Create(GetCfgBool('testnet', True)));
  LCfg.AddPair('aiKey',        GetCfgStr('aiKey', ''));
  LCfg.AddPair('aiModel',      GetCfgStr('aiModel', 'gpt-4o-mini'));
  LCfg.AddPair('aiBaseURL',    GetCfgStr('aiBaseURL', ''));
  LCfg.AddPair('tradeAmount',  GetCfgStr('tradeAmount', '100'));
  LCfg.AddPair('stopLoss',     GetCfgStr('stopLoss', '2.0'));
  LCfg.AddPair('takeProfit',   GetCfgStr('takeProfit', '4.0'));
  LCfg.AddPair('minConfidence',GetCfgStr('minConfidence', '70'));
  LCfg.AddPair('botInterval',  GetCfgStr('botInterval', '300'));
  LCfg.AddPair('autoTrade',    TJSONBool.Create(GetCfgBool('autoTrade', False)));
  LCfg.AddPair('interval',     GetCfgStr('interval', '1h'));
  LCfg.AddPair('topCoins',       GetCfgStr('topCoins', '30'));
  LCfg.AddPair('scanMode',      GetCfgStr('scanMode', 'recovery'));
  LCfg.AddPair('recoveryHours', GetCfgStr('recoveryHours', '24'));
  LCfg.AddPair('lateralTimeout', GetCfgStr('lateralTimeout', '24'));
  LCfg.AddPair('tradeCooldown', GetCfgStr('tradeCooldown', '30'));
  LCfg.AddPair('snapshotInterval', GetCfgStr('snapshotInterval', '30'));
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

  // Sincroniza relogio com servidor Binance
  TThread.CreateAnonymousThread(procedure
  begin
    FBinance.SyncServerTime;
  end).Start;

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
  if LScanMode = 'volume' then
    AddLog('Scanner', 'Iniciando scan do mercado (modo: Volume)...')
  else
    AddLog('Scanner', Format('Iniciando scan do mercado (modo: Recuperacao, janela: %dh)...', [Trunc(GetCfgDbl('recoveryHours', 24))]));

  var LTopCount := Trunc(GetCfgDbl('topCoins', 30));
  if LTopCount < 1 then LTopCount := 30;
  var LRecoveryHours := Trunc(GetCfgDbl('recoveryHours', 24));
  var LWindowSize := HoursToWindowSize(LRecoveryHours);

  TThread.CreateAnonymousThread(procedure
  var
    LTickers: TJSONArray;
    LList: TList<TCoinRecovery>;
    I: Integer;
    LObj: TJSONObject;
    LCoin: TCoinRecovery;
    LSymbol: string;
    LChange, LVol: Double;
  begin
    try
      // Modo volume usa sempre ticker 24h (nao precisa de janela custom)
      if LScanMode = 'volume' then
        LTickers := FBinance.GetAll24hTickers
      else
        LTickers := FBinance.GetAllTickersWindow(LWindowSize);

      if LTickers = nil then
      begin
        TThread.Queue(nil, procedure
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
          for I := 0 to LTickers.Count - 1 do
          begin
            LObj := TJSONObject(LTickers.Items[I]);
            LSymbol := LObj.GetValue<string>('symbol', '');

            // Filtra apenas pares USDT com volume minimo
            if not LSymbol.EndsWith('USDT') then Continue;
            LVol := StrToFloatDef(LObj.GetValue<string>('quoteVolume', '0'), 0, FmtDot);
            if LVol < 1000000 then Continue; // Min 1M USDT volume

            LChange := StrToFloatDef(LObj.GetValue<string>('priceChangePercent', '0'), 0, FmtDot);

            // Modo recuperacao: apenas moedas com variacao positiva
            if (LScanMode <> 'volume') and (LChange <= 0) then Continue;

            LCoin.Symbol := LSymbol;
            LCoin.Price := StrToFloatDef(LObj.GetValue<string>('lastPrice', '0'), 0, FmtDot);
            LCoin.PriceChangePercent := LChange;
            LCoin.Volume := StrToFloatDef(LObj.GetValue<string>('volume', '0'), 0, FmtDot);
            LCoin.HighPrice := StrToFloatDef(LObj.GetValue<string>('highPrice', '0'), 0, FmtDot);
            LCoin.LowPrice := StrToFloatDef(LObj.GetValue<string>('lowPrice', '0'), 0, FmtDot);
            LCoin.QuoteVolume := LVol;
            LList.Add(LCoin);
          end;

          if LScanMode = 'volume' then
          begin
            // Modo volume: ordena por volume USDT decrescente
            LList.Sort(TComparer<TCoinRecovery>.Construct(
              function(const A, B: TCoinRecovery): Integer
              begin
                if A.QuoteVolume > B.QuoteVolume then Result := -1
                else if A.QuoteVolume < B.QuoteVolume then Result := 1
                else Result := 0;
              end
            ));
          end
          else
          begin
            // Modo recuperacao: ordena por variacao % decrescente
            LList.Sort(TComparer<TCoinRecovery>.Construct(
              function(const A, B: TCoinRecovery): Integer
              begin
                if A.PriceChangePercent > B.PriceChangePercent then Result := -1
                else if A.PriceChangePercent < B.PriceChangePercent then Result := 1
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

      TThread.Queue(nil, procedure
      var LModeLabel: string;
      begin
        SendTopCoins;
        if LScanMode = 'volume' then LModeLabel := 'por volume' else LModeLabel := 'em recuperacao';
        AddLog('Scanner', Format('Scan completo! %d moedas %s encontradas', [Length(FTopCoins), LModeLabel]));
        FScanning := False;
        var DEnd := TJSONObject.Create;
        DEnd.AddPair('message', '');
        SendToJS('scanProgress', DEnd);

        // Seleciona a #1 automaticamente se nenhuma selecionada
        if (FSelectedSymbol = '') and (Length(FTopCoins) > 0) then
          DoSelectCoin(FTopCoins[0].Symbol);
      end);
    except
      on E: Exception do
        TThread.Queue(nil, procedure
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
begin
  if Symbol = '' then Exit;
  FSelectedSymbol := Symbol;
  FLastAutoTradeSignal := tsHold;  // Reset ao trocar de moeda
  AddLog('Scanner', 'Moeda selecionada: ' + Symbol);

  D := TJSONObject.Create;
  D.AddPair('symbol', Symbol);
  SendToJS('selectedCoin', D);

  // Carrega candles e indicadores em background
  TThread.CreateAnonymousThread(procedure
  var
    LCandles: TCandleArray;
    LIndicators: TTechnicalIndicators;
    LTicker: TJSONObject;
    LPrice24hAgo, LVol24h: Double;
  begin
    try
      LCandles := FBinance.GetKlines(Symbol, GetInterval, 100);
      if Length(LCandles) = 0 then
      begin
        TThread.Queue(nil, procedure begin AddLog('Erro', 'Nenhum candle para ' + Symbol); end);
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
      end);
    except
      on E: Exception do
        TThread.Queue(nil, procedure begin AddLog('Erro', Symbol + ': ' + E.Message); end);
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

      // Verifica posicao aberta para contexto da IA
      var LHasPos: Boolean := False;
      var LBuyPrice: Double := 0;
      for var PIdx := 0 to FOpenPositions.Count - 1 do
        if FOpenPositions[PIdx].Symbol = LSymbol then
        begin
          LHasPos := True;
          LBuyPrice := FOpenPositions[PIdx].BuyPrice;
          Break;
        end;

      // IA ou score tecnico
      if GetCfgStr('aiKey', '') <> '' then
        LAnalysis := FAIEngine.AnalyzeMarket(LSymbol, LIndicators, LCandles, LHasPos, LBuyPrice)
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
        LAnalysis.SuggestedStopLoss := LIndicators.CurrentPrice * (1 - GetCfgDbl('stopLoss', 2) / 100);
        LAnalysis.SuggestedTakeProfit := LIndicators.CurrentPrice * (1 + GetCfgDbl('takeProfit', 4) / 100);
      end;
      FLastAnalysis := LAnalysis;

      TThread.Queue(nil, procedure
      var DA: TJSONObject; LAmt: Double;
      begin
        SendSignal;
        AddLog('Bot', Format('%s -> Sinal: %s | Confianca: %.0f%%',
          [LSymbol, SignalToStr(LAnalysis.Signal), LAnalysis.Confidence]));
        AddLog('Bot', 'Motivo: ' + LAnalysis.Reasoning);

        // Auto-trade (verifica posicoes reais, cooldown e confianca)
        if GetCfgBool('autoTrade', False) and FBotRunning then
        begin
          if LAnalysis.Confidence >= GetCfgDbl('minConfidence', 70) then
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
                AddLog('Bot', Format('%s: Cooldown ativo (%.0fmin restantes)',
                  [LSymbol, LCooldownMin - LElapsedMin]));
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
        TThread.Queue(nil, procedure
        var DA: TJSONObject;
        begin
          AddLog('Erro', E.Message);
          FAnalyzing := False;
          DA := TJSONObject.Create;
          DA.AddPair('active', TJSONBool.Create(False));
          SendToJS('analyzing', DA);
        end);
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
  if Amount <= 0 then begin AddLog('Erro', Format('Quantidade invalida: %.4f', [Amount], FmtDot)); Exit; end;
  if FLastIndicators.CurrentPrice <= 0 then begin AddLog('Erro', 'Preco atual nao disponivel, aguarde carregamento'); Exit; end;

  LQty := Amount / FLastIndicators.CurrentPrice;
  AddLog('Trade', Format('Enviando COMPRA %s: %.8f @ $%.4f ...', [LSymbol, LQty, FLastIndicators.CurrentPrice]));

  TThread.CreateAnonymousThread(procedure
  var LRes: TOrderResult;
  begin
    try
      LRes := FBinance.PlaceOrder(LSymbol, osBuy, otMarket, LQty);
      TThread.Queue(nil, procedure
      var DT: TJSONObject;
      begin
        if LRes.Success then begin
          AddLog('Trade', 'OK! OrderID=' + IntToStr(LRes.OrderId));
          DT := TJSONObject.Create;
          DT.AddPair('timestamp', FormatDateTime('dd/mm/yyyy hh:nn:ss', Now));
          DT.AddPair('symbol', LSymbol);
          DT.AddPair('side', 'BUY');
          DT.AddPair('price', TJSONNumber.Create(FLastIndicators.CurrentPrice));
          DT.AddPair('quantity', TJSONNumber.Create(LQty));
          DT.AddPair('signal', SignalToStrEN(FLastAnalysis.Signal));
          DT.AddPair('confidence', TJSONNumber.Create(FLastAnalysis.Confidence));
          DT.AddPair('orderId', TJSONNumber.Create(LRes.OrderId));
          SendToJS('addTrade', DT);
          // Rastrear posicao aberta
          var LPos: TOpenPosition;
          LPos.Symbol := LSymbol;
          LPos.BuyPrice := FLastIndicators.CurrentPrice;
          LPos.BuyTime := Now;
          LPos.Quantity := LQty;
          FOpenPositions.Add(LPos);
          // Persistir no banco
          FDB.SaveTrade(LSymbol, 'BUY', FLastIndicators.CurrentPrice, LQty,
            SignalToStrEN(FLastAnalysis.Signal), FLastAnalysis.Confidence, LRes.OrderId, Now);
          FDB.SavePosition(LSymbol, FLastIndicators.CurrentPrice, Now, LQty);
          AddLog('Posicao', Format('Aberta: %s | Preco: $%.4f | Qtd: %.8f',
            [LSymbol, LPos.BuyPrice, LPos.Quantity], FmtDot));
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
        TThread.Queue(nil, procedure
        begin
          AddLog('Erro', 'Excecao na COMPRA ' + LSymbol + ': ' + E.Message);
          var DE := TJSONObject.Create;
          DE.AddPair('message', 'Erro COMPRA ' + LSymbol + ': ' + E.Message);
          SendToJS('tradeError', DE);
        end);
    end;
  end).Start;
end;

procedure TfrmMain.DoSell(Amount: Double);
var
  LQty: Double;
  LSymbol: string;
begin
  AddLog('Trade', Format('Venda solicitada: %.2f USDT', [Amount], FmtDot));
  LSymbol := FSelectedSymbol;
  if LSymbol = '' then begin AddLog('Erro', 'Selecione uma moeda primeiro'); Exit; end;
  if not FApiKeyValid then begin AddLog('Erro', 'API Key nao validada! Clique em "Testar Conexao" primeiro.'); Exit; end;
  if Amount <= 0 then begin AddLog('Erro', Format('Quantidade invalida: %.4f', [Amount], FmtDot)); Exit; end;
  if FLastIndicators.CurrentPrice <= 0 then begin AddLog('Erro', 'Preco atual nao disponivel, aguarde carregamento'); Exit; end;

  LQty := Amount / FLastIndicators.CurrentPrice;
  AddLog('Trade', Format('Enviando VENDA %s: %.8f @ $%.4f ...', [LSymbol, LQty, FLastIndicators.CurrentPrice]));

  TThread.CreateAnonymousThread(procedure
  var LRes: TOrderResult;
  begin
    try
      LRes := FBinance.PlaceOrder(LSymbol, osSell, otMarket, LQty);
      TThread.Queue(nil, procedure
      var DT: TJSONObject;
      begin
        if LRes.Success then begin
          AddLog('Trade', 'OK! OrderID=' + IntToStr(LRes.OrderId));
          DT := TJSONObject.Create;
          DT.AddPair('timestamp', FormatDateTime('dd/mm/yyyy hh:nn:ss', Now));
          DT.AddPair('symbol', LSymbol);
          DT.AddPair('side', 'SELL');
          DT.AddPair('price', TJSONNumber.Create(FLastIndicators.CurrentPrice));
          DT.AddPair('quantity', TJSONNumber.Create(LQty));
          DT.AddPair('signal', SignalToStrEN(FLastAnalysis.Signal));
          DT.AddPair('confidence', TJSONNumber.Create(FLastAnalysis.Confidence));
          DT.AddPair('orderId', TJSONNumber.Create(LRes.OrderId));
          SendToJS('addTrade', DT);
          // Persistir no banco
          FDB.SaveTrade(LSymbol, 'SELL', FLastIndicators.CurrentPrice, LQty,
            SignalToStrEN(FLastAnalysis.Signal), FLastAnalysis.Confidence, LRes.OrderId, Now);
          FDB.DeletePosition(LSymbol);
          // Remover posicao aberta do symbol vendido
          for var PI := FOpenPositions.Count - 1 downto 0 do
            if FOpenPositions[PI].Symbol = LSymbol then
            begin
              FOpenPositions.Delete(PI);
              Break;
            end;
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
        TThread.Queue(nil, procedure
        begin
          AddLog('Erro', 'Excecao na VENDA ' + LSymbol + ': ' + E.Message);
          var DE := TJSONObject.Create;
          DE.AddPair('message', 'Erro VENDA ' + LSymbol + ': ' + E.Message);
          SendToJS('tradeError', DE);
        end);
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
  FTimerBot.Interval := Round(GetCfgDbl('botInterval', 300)) * 1000;
  FTimerBot.Enabled := True;
  D := TJSONObject.Create;
  D.AddPair('running', TJSONBool.Create(True));
  SendToJS('botStatus', D);
  AddLog('Bot', Format('INICIADO - intervalo %ds | %d moedas no scan', [Round(GetCfgDbl('botInterval', 300)), Length(FTopCoins)]));
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
        end;
      end);
    except
      on E: Exception do
        TThread.Queue(nil, procedure
        var DC: TJSONObject;
        begin
          DC := TJSONObject.Create;
          DC.AddPair('connected', TJSONBool.Create(False));
          DC.AddPair('testnet', TJSONBool.Create(GetCfgBool('testnet', True)));
          DC.AddPair('authOK', TJSONBool.Create(False));
          SendToJS('connectionStatus', DC);
          AddLog('Erro', 'Teste de conexao falhou: ' + E.Message);
        end);
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

  FreeAndNil(FConfig);
  FConfig := Data.Clone as TJSONObject;

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
  var LURL := GetCfgStr('aiBaseURL', '');
  if LURL <> '' then FAIEngine.BaseURL := LURL
  else FAIEngine.BaseURL := 'https://api.openai.com/v1';

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
            LStopLoss, LChangePercent: Double;
            PI: Integer;
        begin
          DP := TJSONObject.Create;
          DP.AddPair('price', TJSONNumber.Create(LPrice));
          DP.AddPair('symbol', LSym);
          SendToJS('updatePrice', DP);

          // Verifica stop loss em tempo real para o symbol selecionado (sem API extra)
          if FBotRunning and (FOpenPositions.Count > 0) then
          begin
            LStopLoss := GetCfgDbl('stopLoss', 2);
            if LStopLoss > 0 then
              for PI := 0 to FOpenPositions.Count - 1 do
                if (FOpenPositions[PI].Symbol = LSym) and (FOpenPositions[PI].BuyPrice > 0) then
                begin
                  LChangePercent := ((LPrice - FOpenPositions[PI].BuyPrice) / FOpenPositions[PI].BuyPrice) * 100;
                  if LChangePercent <= -LStopLoss then
                  begin
                    AddLog('StopLoss', Format(
                      'STOP LOSS URGENTE: %s | Queda: %.2f%% | Vendendo imediatamente!',
                      [LSym, LChangePercent], FmtDot));
                    DoSell(FOpenPositions[PI].Quantity * LPrice);
                    FLastTradeTime.AddOrSetValue(LSym, Now);
                  end;
                  Break;
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
        TThread.Queue(nil, procedure begin AddLog('Erro', 'Saldo: ' + E.Message); end);
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
        TThread.Queue(nil, procedure
        var DEnd: TJSONObject;
        begin
          AddLog('Erro', 'Carteira: ' + E.Message);
          FRefreshingWallet := False;
          DEnd := TJSONObject.Create;
          DEnd.AddPair('loading', TJSONBool.Create(False));
          SendToJS('walletLoading', DEnd);
        end);
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
    C.AddPair('t', TJSONNumber.Create(DateTimeToUnix(FLastCandles[I].OpenTime, False)));
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
    FConfig.AddPair('aiBaseURL',     Ini.ReadString('AI', 'BaseURL', ''));
    FConfig.AddPair('interval',      Ini.ReadString('Trading', 'Interval', '1h'));
    FConfig.AddPair('tradeAmount',   Ini.ReadString('Trading', 'Amount', '100'));
    FConfig.AddPair('stopLoss',      Ini.ReadString('Trading', 'StopLoss', '2.0'));
    FConfig.AddPair('takeProfit',    Ini.ReadString('Trading', 'TakeProfit', '4.0'));
    FConfig.AddPair('minConfidence', Ini.ReadString('Trading', 'MinConfidence', '70'));
    FConfig.AddPair('botInterval',   Ini.ReadString('Trading', 'BotInterval', '300'));
    FConfig.AddPair('autoTrade',     TJSONBool.Create(Ini.ReadBool('Trading', 'AutoTrade', False)));
    FConfig.AddPair('topCoins',         Ini.ReadString('Trading', 'TopCoins', '30'));
    FConfig.AddPair('scanMode',       Ini.ReadString('Trading', 'ScanMode', 'recovery'));
    FConfig.AddPair('recoveryHours',  Ini.ReadString('Trading', 'RecoveryHours', '24'));
    FConfig.AddPair('lateralTimeout', Ini.ReadString('Trading', 'LateralTimeout', '24'));
    FConfig.AddPair('tradeCooldown', Ini.ReadString('Trading', 'TradeCooldown', '30'));
    FConfig.AddPair('snapshotInterval', Ini.ReadString('Trading', 'SnapshotInterval', '30'));
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
    Ini.WriteString('AI',      'BaseURL',       GetCfgStr('aiBaseURL', ''));
    Ini.WriteString('Trading', 'Interval',      GetCfgStr('interval', '1h'));
    Ini.WriteString('Trading', 'Amount',        GetCfgStr('tradeAmount', '100'));
    Ini.WriteString('Trading', 'StopLoss',      GetCfgStr('stopLoss', '2.0'));
    Ini.WriteString('Trading', 'TakeProfit',    GetCfgStr('takeProfit', '4.0'));
    Ini.WriteString('Trading', 'MinConfidence', GetCfgStr('minConfidence', '70'));
    Ini.WriteString('Trading', 'BotInterval',   GetCfgStr('botInterval', '300'));
    Ini.WriteBool  ('Trading', 'AutoTrade',     GetCfgBool('autoTrade', False));
    Ini.WriteString('Trading', 'TopCoins',         GetCfgStr('topCoins', '30'));
    Ini.WriteString('Trading', 'ScanMode',       GetCfgStr('scanMode', 'recovery'));
    Ini.WriteString('Trading', 'RecoveryHours',  GetCfgStr('recoveryHours', '24'));
    Ini.WriteString('Trading', 'LateralTimeout', GetCfgStr('lateralTimeout', '24'));
    Ini.WriteString('Trading', 'TradeCooldown', GetCfgStr('tradeCooldown', '30'));
    Ini.WriteString('Trading', 'SnapshotInterval', GetCfgStr('snapshotInterval', '30'));
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
  if FBotRunning and not FAnalyzing then
  begin
    // Verifica stop loss e take profit PRIMEIRO (urgente)
    CheckStopLossTakeProfit;
    // Verifica posicoes lateralizadas
    CheckLateralPositions;
    // Bot: re-scan
    if not FScanning then
      DoScan;

    // Analisa TODAS as top coins em uma unica thread
    if Length(FTopCoins) > 0 then
      DoBotAnalyzeAll;
  end;
end;

procedure TfrmMain.DoBotAnalyzeAll;
var
  LCoins: TCoinRecoveryArray;
  LUseAI: Boolean;
  LInterval: string;
  LMinConf, LStopPct, LTPPct, LCooldownMin, LTradeAmt: Double;
  LAutoTrade: Boolean;
begin
  if FAnalyzing then Exit;
  FAnalyzing := True;

  // Captura configs e lista no thread principal
  LCoins := Copy(FTopCoins);
  LUseAI := GetCfgStr('aiKey', '') <> '';
  LInterval := GetInterval;
  LMinConf := GetCfgDbl('minConfidence', 70);
  LStopPct := GetCfgDbl('stopLoss', 2);
  LTPPct := GetCfgDbl('takeProfit', 4);
  LCooldownMin := GetCfgDbl('tradeCooldown', 30);
  LTradeAmt := GetCfgDbl('tradeAmount', 100);
  LAutoTrade := GetCfgBool('autoTrade', False);

  TThread.Queue(nil, procedure
  var DA: TJSONObject;
  begin
    DA := TJSONObject.Create;
    DA.AddPair('active', TJSONBool.Create(True));
    SendToJS('analyzing', DA);
    AddLog('Bot', Format('=== Ciclo: analisando %d moedas ===', [Length(LCoins)]));
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
  begin
    try
      for CI := 0 to High(LCoins) do
      begin
        if not FBotRunning then Break;

        LSymbol := LCoins[CI].Symbol;

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

        // 3. Pre-filtro com score tecnico (rapido, sem gastar tokens)
        LScore := TTechnicalAnalysis.TechnicalScoreEx(LIndicators, LBreakdown);

        // Se score fraco (entre -40 e +40), pula - nao vale a pena gastar IA
        if (Abs(LScore) < 40) and LUseAI then
        begin
          var LSkipMsg := Format('[%d/%d] %s: Score %.0f (fraco) - pulando',
            [CI + 1, Length(LCoins), LSymbol, LScore]);
          TThread.Synchronize(nil, procedure begin AddLog('Bot', LSkipMsg); end);
          Continue;
        end;

        // 4. Verifica posicao para contexto
        LHasPos := False;
        LBuyPrice := 0;
        for var PIdx := 0 to FOpenPositions.Count - 1 do
          if FOpenPositions[PIdx].Symbol = LSymbol then
          begin
            LHasPos := True;
            LBuyPrice := FOpenPositions[PIdx].BuyPrice;
            Break;
          end;

        // Score local ja indica direcao incompativel? Pula sem gastar IA
        if (LScore > 0) and LHasPos and not LUseAI then Continue;   // BUY mas ja tem posicao
        if (LScore < 0) and not LHasPos and not LUseAI then Continue; // SELL mas sem posicao

        // 5. Analise (IA ou score tecnico)
        if LUseAI then
          LAnalysis := FAIEngine.AnalyzeMarket(LSymbol, LIndicators, LCandles, LHasPos, LBuyPrice)
        else
        begin
          LAnalysis.Signal := tsHold;
          LAnalysis.Confidence := Abs(LScore);
          if LScore > 60 then LAnalysis.Signal := tsStrongBuy
          else if LScore > 40 then LAnalysis.Signal := tsBuy
          else if LScore < -60 then LAnalysis.Signal := tsStrongSell
          else if LScore < -40 then LAnalysis.Signal := tsSell;
          LAnalysis.Reasoning := LBreakdown;
          LAnalysis.Timestamp := Now;
          LAnalysis.SuggestedEntry := LIndicators.CurrentPrice;
          LAnalysis.SuggestedStopLoss := LIndicators.CurrentPrice * (1 - LStopPct / 100);
          LAnalysis.SuggestedTakeProfit := LIndicators.CurrentPrice * (1 + LTPPct / 100);
        end;

        // Atualiza UI (Synchronize garante valores corretos)
        var LLogAnalise := Format('[%d/%d] %s -> %s | Confianca: %.0f%%',
          [CI + 1, Length(LCoins), LSymbol, SignalToStr(LAnalysis.Signal), LAnalysis.Confidence]);
        var LLogMotivo := LAnalysis.Reasoning;
        TThread.Synchronize(nil, procedure
        begin
          FSelectedSymbol := LSymbol;
          FLastCandles := LCandles;
          FLastIndicators := LIndicators;
          FLastAnalysis := LAnalysis;
          var DSel := TJSONObject.Create;
          DSel.AddPair('symbol', LSymbol);
          SendToJS('selectedCoin', DSel);
          SendCandles;
          SendIndicators;
          SendSignal;
          AddLog('Bot', LLogAnalise);
          AddLog('Bot', 'Motivo: ' + LLogMotivo);
        end);

        // 6. Auto-trade
        if LAutoTrade and FBotRunning and (LAnalysis.Confidence >= LMinConf) then
        begin
          // Cooldown
          var LLastTime: TDateTime;
          var LInCooldown := False;
          if FLastTradeTime.TryGetValue(LSymbol, LLastTime) then
          begin
            var LElapsed := MinutesBetween(Now, LLastTime) + (SecondsBetween(Now, LLastTime) mod 60) / 60.0;
            if LElapsed < LCooldownMin then LInCooldown := True;
          end;

          if not LInCooldown then
          begin
            if (LAnalysis.Signal in [tsStrongBuy, tsBuy]) and not LHasPos then
            begin
              var LBuyMsg := Format('AUTO-COMPRA %s | Confianca: %.0f%% | %s', [LSymbol, LAnalysis.Confidence, LAnalysis.Reasoning]);
              TThread.Synchronize(nil, procedure
              begin
                FSelectedSymbol := LSymbol;
                FLastIndicators.CurrentPrice := LIndicators.CurrentPrice;
                AddLog('Trade', LBuyMsg);
                DoBuy(LTradeAmt);
                FLastTradeTime.AddOrSetValue(LSymbol, Now);
              end);
              Sleep(2000); // Aguarda DoBuy iniciar
            end
            else if (LAnalysis.Signal in [tsStrongSell, tsSell]) and LHasPos then
            begin
              var LSellMsg := Format('AUTO-VENDA %s | Confianca: %.0f%% | %s', [LSymbol, LAnalysis.Confidence, LAnalysis.Reasoning]);
              TThread.Synchronize(nil, procedure
              begin
                FSelectedSymbol := LSymbol;
                FLastIndicators.CurrentPrice := LIndicators.CurrentPrice;
                AddLog('Trade', LSellMsg);
                DoSell(LTradeAmt);
                FLastTradeTime.AddOrSetValue(LSymbol, Now);
              end);
              Sleep(2000); // Aguarda DoSell iniciar
            end;
          end;
        end;

        Sleep(200); // Pequeno delay entre moedas para nao bater rate limit
      end;

      TThread.Synchronize(nil, procedure
      var DA: TJSONObject;
      begin
        AddLog('Bot', '=== Ciclo completo ===');
        FAnalyzing := False;
        DA := TJSONObject.Create;
        DA.AddPair('active', TJSONBool.Create(False));
        SendToJS('analyzing', DA);
      end);
    except
      on E: Exception do
      begin
        var LErrMsg := 'Ciclo bot: ' + E.Message;
        TThread.Synchronize(nil, procedure
        var DA: TJSONObject;
        begin
          AddLog('Erro', LErrMsg);
          FAnalyzing := False;
          DA := TJSONObject.Create;
          DA.AddPair('active', TJSONBool.Create(False));
          SendToJS('analyzing', DA);
        end);
      end;
    end;
  end).Start;
end;

procedure TfrmMain.CheckLateralPositions;
var
  I: Integer;
  Pos: TOpenPosition;
  LHours, LTimeout, LPriceChange: Double;
  LCurrentPrice: Double;
  LSavedSymbol: string;
  LSavedSignal: TTradeSignal;
begin
  if FOpenPositions.Count = 0 then Exit;
  LTimeout := GetCfgDbl('lateralTimeout', 24);
  if LTimeout <= 0 then Exit;

  for I := FOpenPositions.Count - 1 downto 0 do
  begin
    Pos := FOpenPositions[I];
    LHours := HoursBetween(Now, Pos.BuyTime) + (MinutesBetween(Now, Pos.BuyTime) mod 60) / 60.0;

    if LHours >= LTimeout then
    begin
      // Busca preco atual
      try
        LCurrentPrice := FBinance.GetPrice(Pos.Symbol);
      except
        Continue;
      end;

      if (LCurrentPrice <= 0) or (Pos.BuyPrice <= 0) then Continue;

      LPriceChange := Abs((LCurrentPrice - Pos.BuyPrice) / Pos.BuyPrice) * 100;

      // Se variacao < 3%, esta lateral
      if LPriceChange < 3.0 then
      begin
        AddLog('Lateral', Format(
          'LATERALIZACAO DETECTADA: %s | Tempo: %.1fh | Compra: $%.4f | Atual: $%.4f | Variacao: %.2f%%',
          [Pos.Symbol, LHours, Pos.BuyPrice, LCurrentPrice, LPriceChange], FmtDot));
        AddLog('Lateral', Format(
          'Vendendo %s automaticamente (lateral > %.0fh com variacao < 3%%)',
          [Pos.Symbol, LTimeout], FmtDot));

        // Salva estado atual, seleciona a moeda lateral e vende
        LSavedSymbol := FSelectedSymbol;
        LSavedSignal := FLastAutoTradeSignal;

        FSelectedSymbol := Pos.Symbol;
        FLastIndicators.CurrentPrice := LCurrentPrice;
        DoSell(Pos.Quantity * LCurrentPrice);

        // Restaura estado
        FSelectedSymbol := LSavedSymbol;
        FLastAutoTradeSignal := LSavedSignal;

        Break; // Processa uma por ciclo para nao sobrecarregar
      end
      else
        AddLog('Posicao', Format('%s: %.1fh aberta, variacao %.2f%% (nao lateral)',
          [Pos.Symbol, LHours, LPriceChange], FmtDot));
    end;
  end;
end;

procedure TfrmMain.CheckStopLossTakeProfit;
var
  I: Integer;
  Pos: TOpenPosition;
  LCurrentPrice, LChangePercent: Double;
  LStopLoss, LTakeProfit: Double;
  LSavedSymbol: string;
begin
  if FOpenPositions.Count = 0 then Exit;
  if not FBotRunning then Exit;

  LStopLoss := GetCfgDbl('stopLoss', 2);
  LTakeProfit := GetCfgDbl('takeProfit', 4);

  // Se ambos estao zerados, nao verifica
  if (LStopLoss <= 0) and (LTakeProfit <= 0) then Exit;

  for I := FOpenPositions.Count - 1 downto 0 do
  begin
    Pos := FOpenPositions[I];
    if Pos.BuyPrice <= 0 then Continue;

    try
      LCurrentPrice := FBinance.GetPrice(Pos.Symbol);
    except
      Continue;
    end;
    if LCurrentPrice <= 0 then Continue;

    LChangePercent := ((LCurrentPrice - Pos.BuyPrice) / Pos.BuyPrice) * 100;

    // Stop Loss: preco caiu mais que o limite configurado
    if (LStopLoss > 0) and (LChangePercent <= -LStopLoss) then
    begin
      AddLog('StopLoss', Format(
        'STOP LOSS ACIONADO: %s | Compra: $%s | Atual: $%s | Queda: %.2f%%',
        [Pos.Symbol,
         FormatFloat('0.########', Pos.BuyPrice, FmtDot),
         FormatFloat('0.########', LCurrentPrice, FmtDot),
         LChangePercent], FmtDot));

      LSavedSymbol := FSelectedSymbol;
      FSelectedSymbol := Pos.Symbol;
      FLastIndicators.CurrentPrice := LCurrentPrice;
      // Vende toda a posicao
      DoSell(Pos.Quantity * LCurrentPrice);
      FSelectedSymbol := LSavedSymbol;
      FLastTradeTime.AddOrSetValue(Pos.Symbol, Now);

      Break; // Processa uma por ciclo
    end
    // Take Profit: preco subiu mais que o limite configurado
    else if (LTakeProfit > 0) and (LChangePercent >= LTakeProfit) then
    begin
      AddLog('TakeProfit', Format(
        'TAKE PROFIT ACIONADO: %s | Compra: $%s | Atual: $%s | Ganho: +%.2f%%',
        [Pos.Symbol,
         FormatFloat('0.########', Pos.BuyPrice, FmtDot),
         FormatFloat('0.########', LCurrentPrice, FmtDot),
         LChangePercent], FmtDot));

      LSavedSymbol := FSelectedSymbol;
      FSelectedSymbol := Pos.Symbol;
      FLastIndicators.CurrentPrice := LCurrentPrice;
      DoSell(Pos.Quantity * LCurrentPrice);
      FSelectedSymbol := LSavedSymbol;
      FLastTradeTime.AddOrSetValue(Pos.Symbol, Now);

      Break; // Processa uma por ciclo
    end
    ;
  end;
end;

end.
