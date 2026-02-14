unit uAIEngine;

interface

uses
  System.SysUtils, System.Classes, System.JSON, System.Math,
  System.Net.HttpClient, System.Net.URLClient,
  uTypes;

type
  TAIEngine = class
  private
    FApiKey, FModel, FBaseURL: string;
    FHttp: THTTPClient;
    FOnLog: TProc<string>;
    procedure Log(const Msg: string);
    function CallLLM(const SystemPrompt, UserPrompt: string): string;
    function ParseResponse(const Resp: string): TAIAnalysis;
    function BuildPrompt(const Symbol: string; const Ind: TTechnicalIndicators; const C: TCandleArray): string;
  public
    constructor Create(const AApiKey: string; const AModel: string = 'gpt-4o-mini');
    destructor Destroy; override;
    function AnalyzeMarket(const Symbol: string; const Ind: TTechnicalIndicators; const C: TCandleArray): TAIAnalysis;
    property ApiKey: string read FApiKey write FApiKey;
    property Model: string read FModel write FModel;
    property BaseURL: string read FBaseURL write FBaseURL;
    property OnLog: TProc<string> read FOnLog write FOnLog;
  end;

implementation

constructor TAIEngine.Create(const AApiKey, AModel: string);
begin
  inherited Create;
  FApiKey := AApiKey; FModel := AModel;
  FBaseURL := 'https://api.openai.com/v1';
  FHttp := THTTPClient.Create;
  FHttp.ConnectionTimeout := 15000;
  FHttp.ResponseTimeout := 60000;
end;

destructor TAIEngine.Destroy;
begin
  FHttp.Free;
  inherited;
end;

procedure TAIEngine.Log(const Msg: string);
begin
  if Assigned(FOnLog) then FOnLog(Msg);
end;

function TAIEngine.CallLLM(const SystemPrompt, UserPrompt: string): string;
var Req: TJSONObject; Msgs: TJSONArray; SM, UM: TJSONObject;
    Src: TStringStream; Resp: IHTTPResponse; RJ: TJSONValue; Ch: TJSONArray;
begin
  Result := '';
  Req := TJSONObject.Create;
  try
    Req.AddPair('model', FModel);
    Req.AddPair('temperature', TJSONNumber.Create(0.3));
    Req.AddPair('max_tokens', TJSONNumber.Create(2000));
    Msgs := TJSONArray.Create;
    SM := TJSONObject.Create; SM.AddPair('role','system'); SM.AddPair('content', SystemPrompt); Msgs.AddElement(SM);
    UM := TJSONObject.Create; UM.AddPair('role','user'); UM.AddPair('content', UserPrompt); Msgs.AddElement(UM);
    Req.AddPair('messages', Msgs);

    Src := TStringStream.Create(Req.ToJSON, TEncoding.UTF8);
    try
      FHttp.CustomHeaders['Authorization'] := 'Bearer ' + FApiKey;
      FHttp.CustomHeaders['Content-Type'] := 'application/json';
      Log('Enviando para ' + FModel + '...');
      Resp := FHttp.Post(FBaseURL + '/chat/completions', Src, nil,
        [TNameValuePair.Create('Content-Type','application/json')]);
      if Resp.StatusCode = 200 then begin
        RJ := TJSONObject.ParseJSONValue(Resp.ContentAsString(TEncoding.UTF8));
        try
          if RJ <> nil then begin
            Ch := TJSONObject(RJ).GetValue<TJSONArray>('choices');
            if (Ch <> nil) and (Ch.Count > 0) then
              Result := TJSONObject(Ch.Items[0]).GetValue<TJSONObject>('message').GetValue<string>('content');
          end;
        finally RJ.Free; end;
        Log('Resposta recebida');
      end else
        Log('Erro API: ' + IntToStr(Resp.StatusCode));
    finally Src.Free; end;
  finally Req.Free; end;
end;

function TAIEngine.BuildPrompt(const Symbol: string; const Ind: TTechnicalIndicators; const C: TCandleArray): string;
var S: string; I, Start: Integer;
begin
  S := '';
  Start := Max(0, Length(C)-20);
  for I := Start to High(C) do
    S := S + Format('%.2f, %.2f, %.2f, %.2f, Vol:%.0f'#13#10,
      [C[I].Open, C[I].High, C[I].Low, C[I].Close, C[I].Volume]);
  Result := Format(
    'Analise o par %s.'#13#10#13#10 +
    '=== INDICADORES ==='#13#10'%s'#13#10#13#10 +
    '=== ULTIMOS CANDLES (O,H,L,C,Vol) ==='#13#10'%s',
    [Symbol, Ind.ToText, S]);
end;

function TAIEngine.ParseResponse(const Resp: string): TAIAnalysis;
var J: TJSONValue; O: TJSONObject; U: string;
begin
  Result.Timestamp := Now; Result.Signal := tsHold; Result.Confidence := 50;
  Result.Reasoning := Resp;
  Result.SuggestedEntry := 0; Result.SuggestedStopLoss := 0; Result.SuggestedTakeProfit := 0;

  J := TJSONObject.ParseJSONValue(Resp);
  if J <> nil then begin
    try
      if J is TJSONObject then begin
        O := TJSONObject(J);
        U := O.GetValue<string>('signal','HOLD').ToUpper;
        if U = 'STRONG_BUY' then Result.Signal := tsStrongBuy
        else if U = 'BUY' then Result.Signal := tsBuy
        else if U = 'SELL' then Result.Signal := tsSell
        else if U = 'STRONG_SELL' then Result.Signal := tsStrongSell;
        Result.Confidence := O.GetValue<Double>('confidence', 50);
        Result.Reasoning := O.GetValue<string>('reasoning', Resp);
        Result.SuggestedEntry := O.GetValue<Double>('entry_price', 0);
        Result.SuggestedStopLoss := O.GetValue<Double>('stop_loss', 0);
        Result.SuggestedTakeProfit := O.GetValue<Double>('take_profit', 0);
      end;
    finally J.Free; end;
    Exit;
  end;

  // Fallback text parsing
  U := Resp.ToUpper;
  if Pos('STRONG_BUY', U) > 0 then Result.Signal := tsStrongBuy
  else if Pos('STRONG_SELL', U) > 0 then Result.Signal := tsStrongSell
  else if (Pos('BUY', U) > 0) or (Pos('COMPRA', U) > 0) then Result.Signal := tsBuy
  else if (Pos('SELL', U) > 0) or (Pos('VENDA', U) > 0) then Result.Signal := tsSell;
end;

function TAIEngine.AnalyzeMarket(const Symbol: string; const Ind: TTechnicalIndicators; const C: TCandleArray): TAIAnalysis;
const
  SYS_PROMPT =
    'Voce e um analista de trading de criptomoedas experiente. '#13#10 +
    'Analise os indicadores e retorne APENAS JSON:'#13#10 +
    '{"signal":"STRONG_BUY|BUY|HOLD|SELL|STRONG_SELL","confidence":0-100,' +
    '"reasoning":"explicacao","entry_price":0,"stop_loss":0,"take_profit":0}'#13#10 +
    'Regras: RSI<30=sobrevendido, RSI>70=sobrecomprado, MACD acima signal=compra, ' +
    'SMA20>SMA50=alta, preco<BollingerInf=bounce, ATR para stop loss, risco/retorno 1:2 minimo. ' +
    'Seja conservador, prefira HOLD sem sinal claro.';
var
  Resp: string;
begin
  Log('Analisando ' + Symbol + '...');
  Resp := CallLLM(SYS_PROMPT, BuildPrompt(Symbol, Ind, C));
  if Resp <> '' then begin
    Result := ParseResponse(Resp);
    Log(Format('Sinal: %s | Confianca: %.0f%%', [SignalToStr(Result.Signal), Result.Confidence]));
  end else begin
    Result.Signal := tsHold; Result.Confidence := 0;
    Result.Reasoning := 'Falha na comunicacao com a IA'; Result.Timestamp := Now;
    Log('Falha na analise');
  end;
end;

end.
