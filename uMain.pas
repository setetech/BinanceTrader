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
    FLastAutoTradeSignal: TTradeSignal;  // Evita trades repetidos no mesmo sinal
    FRefreshingWallet: Boolean;
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
  FSelectedSymbol := '';
  FConfig := TJSONObject.Create;
  FOpenPositions := TList<TOpenPosition>.Create;


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
  FDB := TDatabase.Create(ExtractFilePath(Application.ExeName) + 'BinanceBot.db');
  // Carregar posicoes abertas do banco
  FreeAndNil(FOpenPositions);
  FOpenPositions := FDB.LoadPositions;

  FBinance := TBinanceAPI.Create(
    GetCfgStr('apiKey', ''),
    GetCfgStr('secretKey', ''),
    GetCfgBool('testnet', True)
  );
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
  LCfg.AddPair('apiKey',       GetCfgStr('apiKey', ''));
  LCfg.AddPair('secretKey',    GetCfgStr('secretKey', ''));
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
  LCfg.AddPair('topCoins',     GetCfgStr('topCoins', '30'));
  LCfg.AddPair('lateralTimeout', GetCfgStr('lateralTimeout', '24'));
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
  AddLog('Scanner', 'Iniciando scan do mercado...');

  var LTopCount := Trunc(GetCfgDbl('topCoins', 30));
  if LTopCount < 1 then LTopCount := 30;

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
      LTickers := FBinance.GetAll24hTickers;
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
            if LChange <= 0 then Continue; // Apenas moedas em recuperacao

            LCoin.Symbol := LSymbol;
            LCoin.Price := StrToFloatDef(LObj.GetValue<string>('lastPrice', '0'), 0, FmtDot);
            LCoin.PriceChangePercent := LChange;
            LCoin.Volume := StrToFloatDef(LObj.GetValue<string>('volume', '0'), 0, FmtDot);
            LCoin.HighPrice := StrToFloatDef(LObj.GetValue<string>('highPrice', '0'), 0, FmtDot);
            LCoin.LowPrice := StrToFloatDef(LObj.GetValue<string>('lowPrice', '0'), 0, FmtDot);
            LCoin.QuoteVolume := LVol;
            LList.Add(LCoin);
          end;

          // Ordena por variacao % decrescente
          LList.Sort(TComparer<TCoinRecovery>.Construct(
            function(const A, B: TCoinRecovery): Integer
            begin
              if A.PriceChangePercent > B.PriceChangePercent then Result := -1
              else if A.PriceChangePercent < B.PriceChangePercent then Result := 1
              else Result := 0;
            end
          ));

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
      begin
        SendTopCoins;
        AddLog('Scanner', Format('Scan completo! %d moedas em recuperacao encontradas', [Length(FTopCoins)]));
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

      // IA ou score tecnico
      if GetCfgStr('aiKey', '') <> '' then
        LAnalysis := FAIEngine.AnalyzeMarket(LSymbol, LIndicators, LCandles)
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

        // Auto-trade (com protecao contra trades repetidos)
        if GetCfgBool('autoTrade', False) and FBotRunning then
        begin
          if LAnalysis.Confidence >= GetCfgDbl('minConfidence', 70) then
          begin
            // Verifica se o sinal mudou em relacao ao ultimo trade
            if (LAnalysis.Signal in [tsStrongBuy, tsBuy]) and
               (FLastAutoTradeSignal in [tsStrongBuy, tsBuy]) then
            begin
              AddLog('Bot', LSymbol + ': Ja comprado, aguardando sinal de venda');
            end
            else if (LAnalysis.Signal in [tsStrongSell, tsSell]) and
                    (FLastAutoTradeSignal in [tsStrongSell, tsSell]) then
            begin
              AddLog('Bot', LSymbol + ': Ja vendido, aguardando sinal de compra');
            end
            else
            begin
              LAmt := GetCfgDbl('tradeAmount', 100);
              case LAnalysis.Signal of
                tsStrongBuy, tsBuy:
                begin
                  AddLog('Trade', Format('AUTO-COMPRA %s | Motivo: %s', [LSymbol, LAnalysis.Reasoning]));
                  DoBuy(LAmt);
                  FLastAutoTradeSignal := LAnalysis.Signal;
                end;
                tsStrongSell, tsSell:
                begin
                  AddLog('Trade', Format('AUTO-VENDA %s | Motivo: %s', [LSymbol, LAnalysis.Reasoning]));
                  DoSell(LAmt);
                  FLastAutoTradeSignal := LAnalysis.Signal;
                end;
              else
                AddLog('Bot', LSymbol + ': HOLD - sem sinal claro');
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
  if Amount <= 0 then begin AddLog('Erro', Format('Quantidade invalida: %.4f', [Amount], FmtDot)); Exit; end;
  if FLastIndicators.CurrentPrice <= 0 then begin AddLog('Erro', 'Preco atual nao disponivel, aguarde carregamento'); Exit; end;

  LQty := Amount / FLastIndicators.CurrentPrice;
  AddLog('Trade', Format('COMPRA %s: %.8f @ $%.4f', [LSymbol, LQty, FLastIndicators.CurrentPrice]));

  TThread.CreateAnonymousThread(procedure
  var LRes: TOrderResult;
  begin
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
        AddLog('Erro', LRes.ErrorMsg);
    end);
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
  if Amount <= 0 then begin AddLog('Erro', Format('Quantidade invalida: %.4f', [Amount], FmtDot)); Exit; end;
  if FLastIndicators.CurrentPrice <= 0 then begin AddLog('Erro', 'Preco atual nao disponivel, aguarde carregamento'); Exit; end;

  LQty := Amount / FLastIndicators.CurrentPrice;
  AddLog('Trade', Format('VENDA %s: %.8f @ $%.4f', [LSymbol, LQty, FLastIndicators.CurrentPrice]));

  TThread.CreateAnonymousThread(procedure
  var LRes: TOrderResult;
  begin
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
        AddLog('Erro', LRes.ErrorMsg);
    end);
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
  FTimerBot.Interval := Round(GetCfgDbl('botInterval', 300)) * 1000;
  FTimerBot.Enabled := True;
  D := TJSONObject.Create;
  D.AddPair('running', TJSONBool.Create(True));
  SendToJS('botStatus', D);
  AddLog('Bot', Format('INICIADO - intervalo %ds', [Round(GetCfgDbl('botInterval', 300))]));
  Caption := 'Binance Recovery Bot [BOT ATIVO]';

  // Primeira analise
  if FSelectedSymbol <> '' then
    DoAnalyze
  else if Length(FTopCoins) > 0 then
  begin
    DoSelectCoin(FTopCoins[0].Symbol);
    // Analise sera feita no proximo ciclo do bot
  end;
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
  TThread.CreateAnonymousThread(procedure
  var LOK: Boolean;
  begin
    FBinance.SyncServerTime;
    LOK := FBinance.TestConnectivity;
    TThread.Queue(nil, procedure
    var DC: TJSONObject;
    begin
      DC := TJSONObject.Create;
      DC.AddPair('connected', TJSONBool.Create(LOK));
      DC.AddPair('testnet', TJSONBool.Create(GetCfgBool('testnet', True)));
      SendToJS('connectionStatus', DC);
      if LOK then begin AddLog('Binance', 'Conexao OK! Tempo sincronizado.'); UpdateBalance; end
      else AddLog('Erro', 'Falha na conexao');
    end);
  end).Start;
end;

{ ================================================================
  SAVE CONFIG
  ================================================================ }

procedure TfrmMain.DoSaveConfig(Data: TJSONObject);
begin
  if Data = nil then Exit;
  FreeAndNil(FConfig);
  FConfig := Data.Clone as TJSONObject;

  FBinance.ApiKey := GetCfgStr('apiKey', '');
  FBinance.SecretKey := GetCfgStr('secretKey', '');
  FBinance.UseTestnet := GetCfgBool('testnet', True);
  FBinance.UpdateBaseURL;

  FAIEngine.ApiKey := GetCfgStr('aiKey', '');
  FAIEngine.Model := GetCfgStr('aiModel', 'gpt-4o-mini');
  var LURL := GetCfgStr('aiBaseURL', '');
  if LURL <> '' then FAIEngine.BaseURL := LURL
  else FAIEngine.BaseURL := 'https://api.openai.com/v1';

  SaveConfig;
  AddLog('Sistema', 'Configuracoes salvas!');
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
        begin
          DP := TJSONObject.Create;
          DP.AddPair('price', TJSONNumber.Create(LPrice));
          DP.AddPair('symbol', LSym);
          SendToJS('updatePrice', DP);
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
    FConfig.AddPair('apiKey',        Ini.ReadString('Binance', 'ApiKey', ''));
    FConfig.AddPair('secretKey',     Ini.ReadString('Binance', 'SecretKey', ''));
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
    FConfig.AddPair('lateralTimeout', Ini.ReadString('Trading', 'LateralTimeout', '24'));
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
    Ini.WriteString('Binance', 'ApiKey',        GetCfgStr('apiKey', ''));
    Ini.WriteString('Binance', 'SecretKey',     GetCfgStr('secretKey', ''));
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
    Ini.WriteString('Trading', 'LateralTimeout', GetCfgStr('lateralTimeout', '24'));
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
    // Verifica posicoes lateralizadas antes de tudo
    CheckLateralPositions;
    // Bot: re-scan e analisa a melhor moeda
    if not FScanning then
      DoScan;
    // Analisa a moeda selecionada (ou a #1 do scan)
    if FSelectedSymbol <> '' then
      DoAnalyze;
  end;
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

end.
