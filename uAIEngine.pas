unit uAIEngine;

interface

uses
  System.SysUtils, System.Classes, System.JSON, System.Math,
  System.Net.HttpClient, System.Net.URLClient, System.NetEncoding,
  Vcl.Graphics, Vcl.Imaging.pngimage,
  uTypes;

type
  TAIEngine = class
  private
    FApiKey, FModel, FBaseURL: string;
    FIsVisionModel: Boolean;
    FIsThinkingModel: Boolean;
    FHttp: THTTPClient;
    FOnLog: TProc<string>;
    FLastPromptTokens: Integer;
    FLastCompletionTokens: Integer;
    FLastTotalTokens: Integer;
    procedure Log(const Msg: string);
    procedure SetModel(const Value: string);
    function CallLLM(const SystemPrompt, UserPrompt: string;
      const ImageBase64: string = ''): string;
    function ParseResponse(const Resp: string): TAIAnalysis;
    function BuildPrompt(const Symbol: string; const Ind: TTechnicalIndicators;
      const C: TCandleArray; HasPosition: Boolean; BuyPrice: Double): string;
    function GenerateChartBase64(const C: TCandleArray): string;
    function StripThinkTags(const S: string): string;
  public
    constructor Create(const AApiKey: string; const AModel: string = 'gpt-4o-mini');
    destructor Destroy; override;
    function AnalyzeMarket(const Symbol: string; const Ind: TTechnicalIndicators;
      const C: TCandleArray; HasPosition: Boolean = False; BuyPrice: Double = 0): TAIAnalysis;
    property ApiKey: string read FApiKey write FApiKey;
    property Model: string read FModel write SetModel;
    property BaseURL: string read FBaseURL write FBaseURL;
    property IsVisionModel: Boolean read FIsVisionModel;
    property IsThinkingModel: Boolean read FIsThinkingModel;
    property OnLog: TProc<string> read FOnLog write FOnLog;
    property LastPromptTokens: Integer read FLastPromptTokens;
    property LastCompletionTokens: Integer read FLastCompletionTokens;
    property LastTotalTokens: Integer read FLastTotalTokens;
  end;

implementation

constructor TAIEngine.Create(const AApiKey, AModel: string);
begin
  inherited Create;
  FApiKey := AApiKey;
  SetModel(AModel);
  FBaseURL := 'https://api.openai.com/v1';
  FHttp := THTTPClient.Create;
  FHttp.ConnectionTimeout := 10000;
  FHttp.ResponseTimeout := 120000;
end;

destructor TAIEngine.Destroy;
begin
  FHttp.Free;
  inherited;
end;

procedure TAIEngine.SetModel(const Value: string);
var U: string;
begin
  FModel := Value;
  U := Value.ToLower;
  FIsVisionModel := (Pos('vl', U) > 0) or (Pos('vision', U) > 0) or
                    (Pos('gpt-4o', U) > 0) or (Pos('gemini', U) > 0);
  FIsThinkingModel := (Pos('qwen3', U) > 0) or (Pos('deepseek-r', U) > 0) or
                      (Pos('qwq', U) > 0);
end;

procedure TAIEngine.Log(const Msg: string);
begin
  if Assigned(FOnLog) then FOnLog(Msg);
end;

function TAIEngine.StripThinkTags(const S: string): string;
var P1, P2: Integer;
begin
  Result := S;
  // Qwen3 models may include <think>...</think> reasoning blocks
  P1 := Pos('<think>', Result);
  if P1 > 0 then
  begin
    P2 := Pos('</think>', Result);
    if P2 > P1 then
      // Normal case: strip think block, keep content after </think>
      Result := Copy(Result, 1, P1 - 1) + Copy(Result, P2 + 8, MaxInt)
    else
    begin
      // </think> missing (response was truncated by max_tokens)
      // Try to find JSON after the last occurrence of common patterns
      P2 := Pos('JSON:', Result);
      if P2 = 0 then P2 := Pos('```json', Result);
      if P2 = 0 then
      begin
        // Search backwards for last { that might be JSON start
        P2 := Length(Result);
        while (P2 > P1) and (Result[P2] <> '{') do Dec(P2);
        if P2 > P1 then
          Result := Copy(Result, P2, MaxInt)
        else
          Result := ''; // Entire response is think block, no useful content
      end
      else
        Result := Copy(Result, P2, MaxInt);
    end;
  end;
  Result := Result.Trim;
  // Clean "JSON:" prefix if present
  if Result.StartsWith('JSON:') then
    Result := Copy(Result, 6, MaxInt).Trim;
end;

{ Chart image generation for vision models }

function TAIEngine.GenerateChartBase64(const C: TCandleArray): string;
const
  W = 800; H = 450;
  ML = 70;  // margin left
  MR = 15;  // margin right
  MT = 20;  // margin top
  MB = 30;  // margin bottom
  VH = 55;  // volume area height
var
  Bmp: TBitmap;
  Png: TPngImage;
  Stream: TMemoryStream;
  Bytes: TBytes;
  Start, Count, I, CW, Gap, X, MidX: Integer;
  MinP, MaxP, PRange, MaxVol: Double;
  PriceTop, PriceBot, VolTop, VolBot: Integer;
  YO, YC, YH, YL, YTop, YBot: Integer;
  IsGreen, FirstPt: Boolean;
  SMAVal: Double;
  Color: TColor;

  function PriceToY(Price: Double): Integer;
  begin
    Result := PriceTop + Round((MaxP - Price) / PRange * (PriceBot - PriceTop));
  end;

  function VolToY(Vol: Double): Integer;
  begin
    if MaxVol > 0 then
      Result := VolBot - Round((Vol / MaxVol) * (VolBot - VolTop))
    else
      Result := VolBot;
  end;

  function CalcSMA(EndIdx, Period: Integer): Double;
  var J: Integer; Sum: Double;
  begin
    Result := 0;
    if EndIdx < Period - 1 then Exit;
    Sum := 0;
    for J := EndIdx - Period + 1 to EndIdx do
      Sum := Sum + C[J].Close;
    Result := Sum / Period;
  end;

begin
  Result := '';
  if Length(C) < 20 then Exit;

  Start := Max(0, Length(C) - 60);
  Count := Length(C) - Start;

  // Price range
  MinP := C[Start].Low;
  MaxP := C[Start].High;
  MaxVol := C[Start].Volume;
  for I := Start to High(C) do
  begin
    if C[I].Low < MinP then MinP := C[I].Low;
    if C[I].High > MaxP then MaxP := C[I].High;
    if C[I].Volume > MaxVol then MaxVol := C[I].Volume;
  end;
  PRange := MaxP - MinP;
  if PRange <= 0 then Exit;
  MinP := MinP - PRange * 0.05;
  MaxP := MaxP + PRange * 0.05;
  PRange := MaxP - MinP;

  PriceTop := MT;
  PriceBot := H - MB - VH - 8;
  VolTop := PriceBot + 8;
  VolBot := H - MB;
  Gap := 2;
  CW := Max(3, (W - ML - MR - Count * Gap) div Count);

  Bmp := TBitmap.Create;
  try
    Bmp.SetSize(W, H);
    Bmp.PixelFormat := pf32bit;

    // Dark background
    Bmp.Canvas.Brush.Color := $00201A17;
    Bmp.Canvas.FillRect(Rect(0, 0, W, H));

    // Grid lines + price labels
    Bmp.Canvas.Pen.Style := psDot;
    Bmp.Canvas.Pen.Color := $00383838;
    Bmp.Canvas.Pen.Width := 1;
    Bmp.Canvas.Font.Color := $00888888;
    Bmp.Canvas.Font.Size := 7;
    Bmp.Canvas.Font.Name := 'Consolas';
    Bmp.Canvas.Brush.Style := bsClear;
    for I := 0 to 5 do
    begin
      YTop := PriceTop + (PriceBot - PriceTop) * I div 5;
      Bmp.Canvas.MoveTo(ML, YTop);
      Bmp.Canvas.LineTo(W - MR, YTop);
      Bmp.Canvas.TextOut(2, YTop - 6,
        FormatFloat('0.######', MaxP - PRange * I / 5));
    end;

    // Volume separator
    Bmp.Canvas.Pen.Style := psSolid;
    Bmp.Canvas.Pen.Color := $00404040;
    Bmp.Canvas.MoveTo(ML, VolTop - 4);
    Bmp.Canvas.LineTo(W - MR, VolTop - 4);

    // Draw candles + volume
    Bmp.Canvas.Pen.Style := psSolid;
    for I := 0 to Count - 1 do
    begin
      X := ML + I * (CW + Gap);
      IsGreen := C[Start + I].Close >= C[Start + I].Open;
      if IsGreen then Color := $0000CC66 else Color := $004444EE;

      // Wick
      MidX := X + CW div 2;
      Bmp.Canvas.Pen.Color := Color;
      YH := PriceToY(C[Start + I].High);
      YL := PriceToY(C[Start + I].Low);
      Bmp.Canvas.MoveTo(MidX, YH);
      Bmp.Canvas.LineTo(MidX, YL);

      // Body
      Bmp.Canvas.Brush.Style := bsSolid;
      Bmp.Canvas.Brush.Color := Color;
      YO := PriceToY(C[Start + I].Open);
      YC := PriceToY(C[Start + I].Close);
      YTop := Min(YO, YC);
      YBot := Max(YO, YC);
      if YBot - YTop < 1 then YBot := YTop + 1;
      Bmp.Canvas.FillRect(Rect(X, YTop, X + CW, YBot));

      // Volume bar
      if IsGreen then
        Bmp.Canvas.Brush.Color := $0000994D
      else
        Bmp.Canvas.Brush.Color := $003333BB;
      Bmp.Canvas.FillRect(Rect(X, VolToY(C[Start + I].Volume), X + CW, VolBot));
    end;

    // SMA20 (cyan)
    Bmp.Canvas.Pen.Color := $00FFFF00;
    Bmp.Canvas.Pen.Width := 2;
    Bmp.Canvas.Pen.Style := psSolid;
    Bmp.Canvas.Brush.Style := bsClear;
    FirstPt := True;
    for I := 0 to Count - 1 do
    begin
      SMAVal := CalcSMA(Start + I, 20);
      if SMAVal > 0 then
      begin
        MidX := ML + I * (CW + Gap) + CW div 2;
        YTop := PriceToY(SMAVal);
        if FirstPt then
        begin
          Bmp.Canvas.MoveTo(MidX, YTop);
          FirstPt := False;
        end
        else
          Bmp.Canvas.LineTo(MidX, YTop);
      end;
    end;

    // SMA50 (orange)
    Bmp.Canvas.Pen.Color := $000088FF;
    FirstPt := True;
    for I := 0 to Count - 1 do
    begin
      SMAVal := CalcSMA(Start + I, 50);
      if SMAVal > 0 then
      begin
        MidX := ML + I * (CW + Gap) + CW div 2;
        YTop := PriceToY(SMAVal);
        if FirstPt then
        begin
          Bmp.Canvas.MoveTo(MidX, YTop);
          FirstPt := False;
        end
        else
          Bmp.Canvas.LineTo(MidX, YTop);
      end;
    end;

    // Legend
    Bmp.Canvas.Pen.Width := 1;
    Bmp.Canvas.Font.Size := 8;
    Bmp.Canvas.Font.Color := $00FFFF00;
    Bmp.Canvas.TextOut(ML + 5, MT + 2, 'SMA20');
    Bmp.Canvas.Font.Color := $000088FF;
    Bmp.Canvas.TextOut(ML + 60, MT + 2, 'SMA50');
    Bmp.Canvas.Font.Color := $00888888;
    Bmp.Canvas.TextOut(ML + 5, VolTop, 'Volume');

    // Encode to PNG base64
    Png := TPngImage.Create;
    try
      Png.Assign(Bmp);
      Stream := TMemoryStream.Create;
      try
        Png.SaveToStream(Stream);
        Stream.Position := 0;
        SetLength(Bytes, Stream.Size);
        Stream.ReadBuffer(Bytes[0], Stream.Size);
        Result := TNetEncoding.Base64.EncodeBytesToString(Bytes);
      finally
        Stream.Free;
      end;
    finally
      Png.Free;
    end;
  finally
    Bmp.Free;
  end;
end;

{ LLM API call }

function TAIEngine.CallLLM(const SystemPrompt, UserPrompt: string;
  const ImageBase64: string): string;
var
  Req: TJSONObject;
  Msgs: TJSONArray;
  SM, UM: TJSONObject;
  Src: TStringStream;
  Resp: IHTTPResponse;
  RJ: TJSONValue;
  Ch: TJSONArray;
begin
  Result := '';
  FLastPromptTokens := 0;
  FLastCompletionTokens := 0;
  FLastTotalTokens := 0;
  Req := TJSONObject.Create;
  try
    Req.AddPair('model', FModel);
    Req.AddPair('temperature', TJSONNumber.Create(0.3));
    Req.AddPair('max_tokens', TJSONNumber.Create(512));

    Msgs := TJSONArray.Create;

    SM := TJSONObject.Create;
    SM.AddPair('role', 'system');
    SM.AddPair('content', SystemPrompt);
    Msgs.AddElement(SM);

    UM := TJSONObject.Create;
    UM.AddPair('role', 'user');

    if (ImageBase64 <> '') and FIsVisionModel then
    begin
      var ContentArr := TJSONArray.Create;
      var ImgPart := TJSONObject.Create;
      ImgPart.AddPair('type', 'image_url');
      var ImgUrl := TJSONObject.Create;
      ImgUrl.AddPair('url', 'data:image/png;base64,' + ImageBase64);
      ImgPart.AddPair('image_url', ImgUrl);
      ContentArr.AddElement(ImgPart);
      var TextPart := TJSONObject.Create;
      TextPart.AddPair('type', 'text');
      TextPart.AddPair('text', UserPrompt);
      ContentArr.AddElement(TextPart);
      UM.AddPair('content', ContentArr);
    end
    else
      UM.AddPair('content', UserPrompt);

    Msgs.AddElement(UM);
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
        if RJ <> nil then begin
          try
            Ch := TJSONObject(RJ).GetValue<TJSONArray>('choices');
            if (Ch <> nil) and (Ch.Count > 0) then
              Result := TJSONObject(Ch.Items[0]).GetValue<TJSONObject>('message').GetValue<string>('content');
            // Extract token usage
            var Usage := TJSONObject(RJ).GetValue<TJSONObject>('usage');
            if Usage <> nil then
            begin
              FLastPromptTokens := Usage.GetValue<Integer>('prompt_tokens', 0);
              FLastCompletionTokens := Usage.GetValue<Integer>('completion_tokens', 0);
              FLastTotalTokens := Usage.GetValue<Integer>('total_tokens', 0);
            end;
          finally RJ.Free; end;
        end;
        if Result <> '' then
          Log('Resposta recebida: ' + IntToStr(Length(Result)) + ' chars')
        else
          Log('Resposta vazia do modelo');
      end else begin
        Log('Erro HTTP ' + IntToStr(Resp.StatusCode));
      end;
    finally Src.Free; end;
  finally Req.Free; end;
end;

function TAIEngine.BuildPrompt(const Symbol: string; const Ind: TTechnicalIndicators;
  const C: TCandleArray; HasPosition: Boolean; BuyPrice: Double): string;
var S, PosContext: string; I, Start: Integer;
    FmtDot: TFormatSettings;
begin
  FmtDot.DecimalSeparator := '.';
  S := '';
  Start := Max(0, Length(C)-10);
  for I := Start to High(C) do
    S := S + Format('%.2f, %.2f, %.2f, %.2f, Vol:%.0f'#13#10,
      [C[I].Open, C[I].High, C[I].Low, C[I].Close, C[I].Volume]);

  if HasPosition then
    PosContext := Format(
      #13#10'=== POSICAO ABERTA ==='#13#10 +
      'Temos posicao COMPRADA a $%s. Avalie se e momento de VENDER (SELL/STRONG_SELL) ou manter (HOLD). ' +
      'NAO retorne BUY/STRONG_BUY pois ja estamos posicionados.',
      [FormatFloat('0.########', BuyPrice, FmtDot)])
  else
    PosContext :=
      #13#10'=== SEM POSICAO ==='#13#10 +
      'Nao temos posicao neste ativo. Avalie se e momento de COMPRAR (BUY/STRONG_BUY) ou aguardar (HOLD). ' +
      'NAO retorne SELL/STRONG_SELL pois nao temos o que vender.';

  Result := Format(
    'Analise o par %s.'#13#10#13#10 +
    '=== INDICADORES ==='#13#10'%s'#13#10#13#10 +
    '=== ULTIMOS CANDLES (O,H,L,C,Vol) ==='#13#10'%s' +
    '%s',
    [Symbol, Ind.ToText, S, PosContext]);
end;

function TAIEngine.ParseResponse(const Resp: string): TAIAnalysis;
var J: TJSONValue; O: TJSONObject; U, Clean, JsonStr: string;
    P1, P2: Integer;
begin
  Result.Timestamp := Now; Result.Signal := tsHold; Result.Confidence := 50;
  Result.SuggestedEntry := 0; Result.SuggestedStopLoss := 0; Result.SuggestedTakeProfit := 0;

  // Strip <think> tags from Qwen3 models
  Clean := StripThinkTags(Resp);
  if Clean = '' then Clean := Resp;
  Result.Reasoning := Clean; // Always use cleaned version, never raw <think>

  // Try to extract JSON from response (may have markdown fences)
  JsonStr := Clean;
  P1 := Pos('```json', JsonStr);
  if P1 > 0 then
  begin
    Delete(JsonStr, 1, P1 + 6);
    P2 := Pos('```', JsonStr);
    if P2 > 0 then
      JsonStr := Copy(JsonStr, 1, P2 - 1);
  end else begin
    P1 := Pos('{', JsonStr);
    if P1 > 0 then
    begin
      P2 := LastDelimiter('}', JsonStr);
      if P2 > P1 then
        JsonStr := Copy(JsonStr, P1, P2 - P1 + 1);
    end;
  end;

  J := TJSONObject.ParseJSONValue(JsonStr.Trim);
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
        Result.Reasoning := O.GetValue<string>('reasoning', Clean);
        Result.SuggestedEntry := O.GetValue<Double>('entry_price', 0);
        Result.SuggestedStopLoss := O.GetValue<Double>('stop_loss', 0);
        Result.SuggestedTakeProfit := O.GetValue<Double>('take_profit', 0);
      end;
    finally J.Free; end;
    Exit;
  end;

  // JSON parse failed — try to repair truncated JSON
  // Common case: {"signal":"HOLD","confidence":10,"reasoning":"O RSI est...
  P1 := Pos('"signal"', JsonStr);
  if P1 > 0 then
  begin
    // Extract signal manually
    P2 := Pos('"signal"', JsonStr);
    U := Copy(JsonStr, P2, 100).ToUpper;
    if Pos('STRONG_BUY', U) > 0 then Result.Signal := tsStrongBuy
    else if Pos('STRONG_SELL', U) > 0 then Result.Signal := tsStrongSell
    else if Pos('"BUY"', U) > 0 then Result.Signal := tsBuy
    else if Pos('"SELL"', U) > 0 then Result.Signal := tsSell;

    // Extract confidence manually
    P2 := Pos('"confidence"', JsonStr);
    if P2 > 0 then
    begin
      var ConfStr := Copy(JsonStr, P2 + 13, 10);
      // Find number after : and optional space
      var NumStart := 1;
      while (NumStart <= Length(ConfStr)) and not CharInSet(ConfStr[NumStart], ['0'..'9']) do
        Inc(NumStart);
      if NumStart <= Length(ConfStr) then
      begin
        var NumEnd := NumStart;
        while (NumEnd <= Length(ConfStr)) and CharInSet(ConfStr[NumEnd], ['0'..'9','.']) do
          Inc(NumEnd);
        var ConfVal: Double;
        if TryStrToFloat(Copy(ConfStr, NumStart, NumEnd - NumStart), ConfVal) then
          Result.Confidence := ConfVal;
      end;
    end;

    // Extract reasoning manually
    P2 := Pos('"reasoning"', JsonStr);
    if P2 > 0 then
    begin
      var ReasonStart := Pos(':', Copy(JsonStr, P2, MaxInt));
      if ReasonStart > 0 then
      begin
        var Sub := Copy(JsonStr, P2 + ReasonStart, MaxInt);
        // Find opening quote
        var QStart := Pos('"', Sub);
        if QStart > 0 then
        begin
          var QEnd := Pos('"', Copy(Sub, QStart + 1, MaxInt));
          if QEnd > 0 then
            Result.Reasoning := Copy(Sub, QStart + 1, QEnd - 1)
          else
            Result.Reasoning := Copy(Sub, QStart + 1, 500); // Truncated, take what we have
        end;
      end;
    end;

    Log('JSON truncado reparado manualmente');
    Exit;
  end;

  // Final fallback: text parsing
  U := Clean.ToUpper;
  if Pos('STRONG_BUY', U) > 0 then Result.Signal := tsStrongBuy
  else if Pos('STRONG_SELL', U) > 0 then Result.Signal := tsStrongSell
  else if (Pos('BUY', U) > 0) or (Pos('COMPRA', U) > 0) then Result.Signal := tsBuy
  else if (Pos('SELL', U) > 0) or (Pos('VENDA', U) > 0) then Result.Signal := tsSell;
end;

function TAIEngine.AnalyzeMarket(const Symbol: string; const Ind: TTechnicalIndicators;
  const C: TCandleArray; HasPosition: Boolean; BuyPrice: Double): TAIAnalysis;
const
  SYS_PROMPT_TEXT =
    'Voce e um analista de trading de criptomoedas experiente. '#13#10 +
    'Analise os indicadores e retorne APENAS JSON (sem explicacao fora do JSON):'#13#10 +
    '{"signal":"STRONG_BUY|BUY|HOLD|SELL|STRONG_SELL","confidence":0-100,' +
    '"reasoning":"explicacao curta","entry_price":0,"stop_loss":0,"take_profit":0}'#13#10 +
    'Regras: RSI<30=sobrevendido, RSI>70=sobrecomprado, MACD acima signal=compra, ' +
    'SMA20>SMA50=alta, preco<BollingerInf=bounce, ATR para stop loss, risco/retorno 1:2 minimo. ' +
    'IMPORTANTE: Respeite o contexto de posicao informado. Se nao ha posicao, avalie apenas COMPRA ou HOLD. ' +
    'Se ja ha posicao, avalie apenas VENDA ou HOLD. ' +
    'Seja conservador, prefira HOLD sem sinal claro. ' +
    'Responda SOMENTE com o JSON, nada mais.';

  SYS_PROMPT_VISION =
    'Voce e um analista de trading de criptomoedas experiente. '#13#10 +
    'Analise o GRAFICO DE CANDLES fornecido na imagem junto com os indicadores tecnicos. '#13#10 +
    'O grafico mostra: candles (verde=alta, vermelho=baixa), SMA20 (ciano), SMA50 (laranja), volume. '#13#10 +
    'Retorne APENAS JSON (sem explicacao fora do JSON):'#13#10 +
    '{"signal":"STRONG_BUY|BUY|HOLD|SELL|STRONG_SELL","confidence":0-100,' +
    '"reasoning":"explicacao curta","entry_price":0,"stop_loss":0,"take_profit":0}'#13#10 +
    'Regras: RSI<30=sobrevendido, RSI>70=sobrecomprado, MACD acima signal=compra, ' +
    'SMA20>SMA50=alta, preco<BollingerInf=bounce, ATR para stop loss, risco/retorno 1:2 minimo. ' +
    'Use o grafico para identificar padroes visuais: tendencias, suportes, resistencias, ' +
    'padroes de candles (doji, martelo, engolfo, etc). '#13#10 +
    'IMPORTANTE: Respeite o contexto de posicao informado. Se nao ha posicao, avalie apenas COMPRA ou HOLD. ' +
    'Se ja ha posicao, avalie apenas VENDA ou HOLD. ' +
    'Seja conservador, prefira HOLD sem sinal claro. ' +
    'Responda SOMENTE com o JSON, nada mais.';
var
  Resp, ChartB64, SysPrompt: string;
begin
  Log('Analisando ' + Symbol + '...');

  ChartB64 := '';
  SysPrompt := SYS_PROMPT_TEXT;

  if FIsVisionModel then
  begin
    Log('Gerando grafico para modelo de visao...');
    try
      ChartB64 := GenerateChartBase64(C);
      if ChartB64 <> '' then
      begin
        Log('Grafico gerado (' + IntToStr(Length(ChartB64) div 1024) + ' KB)');
        SysPrompt := SYS_PROMPT_VISION;
      end
      else
        Log('Grafico vazio, usando modo texto');
    except
      on E: Exception do
      begin
        Log('Erro ao gerar grafico: ' + E.Message);
        ChartB64 := '';
      end;
    end;
  end;

  var UserPrompt := BuildPrompt(Symbol, Ind, C, HasPosition, BuyPrice);

  Resp := CallLLM(SysPrompt, UserPrompt, ChartB64);
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
