unit uTechnicalAnalysis;

interface

uses
  System.SysUtils, System.Math, uTypes;

type
  TTechnicalAnalysis = class
  private
    class function GetCloses(const C: TCandleArray): TArray<Double>;
    class function CalcSMA(const V: array of Double; P: Integer): Double;
    class function CalcEMA(const V: array of Double; P: Integer): Double;
    class function CalcStdDev(const V: array of Double; P: Integer; M: Double): Double;
  public
    class function RSI(const C: TCandleArray; P: Integer = 14): Double;
    class function SMA(const C: TCandleArray; P: Integer): Double;
    class function EMA(const C: TCandleArray; P: Integer): Double;
    class function MACD(const C: TCandleArray; out Sig, Hist: Double; F:Integer=12; S:Integer=26; Sn:Integer=9): Double;
    class function BollingerBands(const C: TCandleArray; out U, M, L: Double; P:Integer=20; D:Double=2.0): Boolean;
    class function ATR(const C: TCandleArray; P: Integer = 14): Double;
    class function FullAnalysis(const C: TCandleArray; Price24hAgo: Double = 0; Vol24h: Double = 0): TTechnicalIndicators;
    class function TechnicalScore(const I: TTechnicalIndicators): Double;
    class function TechnicalScoreEx(const I: TTechnicalIndicators; out Breakdown: string): Double;
  end;

implementation

class function TTechnicalAnalysis.GetCloses(const C: TCandleArray): TArray<Double>;
var I: Integer;
begin
  SetLength(Result, Length(C));
  for I := 0 to High(C) do Result[I] := C[I].Close;
end;

class function TTechnicalAnalysis.CalcSMA(const V: array of Double; P: Integer): Double;
var I, S: Integer; Sum: Double;
begin
  Result := 0;
  if Length(V) < P then Exit;
  Sum := 0; S := Length(V) - P;
  for I := S to High(V) do Sum := Sum + V[I];
  Result := Sum / P;
end;

class function TTechnicalAnalysis.CalcEMA(const V: array of Double; P: Integer): Double;
var I: Integer; Mul, E: Double;
begin
  Result := 0;
  if Length(V) < P then Exit;
  E := 0;
  for I := 0 to P-1 do E := E + V[I];
  E := E / P;
  Mul := 2.0 / (P + 1);
  for I := P to High(V) do E := (V[I] - E) * Mul + E;
  Result := E;
end;

class function TTechnicalAnalysis.CalcStdDev(const V: array of Double; P: Integer; M: Double): Double;
var I, S: Integer; Sum: Double;
begin
  Result := 0;
  if Length(V) < P then Exit;
  Sum := 0; S := Length(V) - P;
  for I := S to High(V) do Sum := Sum + Sqr(V[I] - M);
  Result := Sqrt(Sum / P);
end;

class function TTechnicalAnalysis.RSI(const C: TCandleArray; P: Integer): Double;
var Pr: TArray<Double>; I: Integer; AG, AL, Ch: Double;
begin
  Result := 50;
  Pr := GetCloses(C);
  if Length(Pr) < P+1 then Exit;
  AG := 0; AL := 0;
  for I := 1 to P do begin
    Ch := Pr[I] - Pr[I-1];
    if Ch > 0 then AG := AG + Ch else AL := AL + Abs(Ch);
  end;
  AG := AG / P; AL := AL / P;
  for I := P+1 to High(Pr) do begin
    Ch := Pr[I] - Pr[I-1];
    if Ch > 0 then begin AG := (AG*(P-1)+Ch)/P; AL := (AL*(P-1))/P; end
    else begin AG := (AG*(P-1))/P; AL := (AL*(P-1)+Abs(Ch))/P; end;
  end;
  if AL = 0 then Result := 100
  else Result := 100 - (100 / (1 + AG/AL));
end;

class function TTechnicalAnalysis.SMA(const C: TCandleArray; P: Integer): Double;
begin Result := CalcSMA(GetCloses(C), P); end;

class function TTechnicalAnalysis.EMA(const C: TCandleArray; P: Integer): Double;
begin Result := CalcEMA(GetCloses(C), P); end;

class function TTechnicalAnalysis.MACD(const C: TCandleArray; out Sig, Hist: Double; F, S, Sn: Integer): Double;
var Pr: TArray<Double>; MV: TArray<Double>; I: Integer;
    EF, ES, MulF, MulS: Double;
begin
  Result := 0; Sig := 0; Hist := 0;
  Pr := GetCloses(C);
  if Length(Pr) < S + Sn then Exit;
  EF := 0; for I := 0 to F-1 do EF := EF + Pr[I]; EF := EF / F;
  ES := 0; for I := 0 to S-1 do ES := ES + Pr[I]; ES := ES / S;
  MulF := 2.0/(F+1); MulS := 2.0/(S+1);
  SetLength(MV, Length(Pr)-S);
  for I := S to High(Pr) do begin
    EF := (Pr[I]-EF)*MulF + EF;
    ES := (Pr[I]-ES)*MulS + ES;
    MV[I-S] := EF - ES;
  end;
  Result := MV[High(MV)];
  if Length(MV) >= Sn then begin
    Sig := CalcEMA(MV, Sn);
    Hist := Result - Sig;
  end;
end;

class function TTechnicalAnalysis.BollingerBands(const C: TCandleArray; out U, M, L: Double; P: Integer; D: Double): Boolean;
var Pr: TArray<Double>; SD: Double;
begin
  Result := False; U:=0; M:=0; L:=0;
  Pr := GetCloses(C);
  if Length(Pr) < P then Exit;
  M := CalcSMA(Pr, P);
  SD := CalcStdDev(Pr, P, M);
  U := M + D*SD; L := M - D*SD;
  Result := True;
end;

class function TTechnicalAnalysis.ATR(const C: TCandleArray; P: Integer): Double;
var I: Integer; TR, Sum: Double; TRs: TArray<Double>;
begin
  Result := 0;
  if Length(C) < P+1 then Exit;
  SetLength(TRs, Length(C)-1);
  for I := 1 to High(C) do begin
    TR := Max(C[I].High-C[I].Low, Max(Abs(C[I].High-C[I-1].Close), Abs(C[I].Low-C[I-1].Close)));
    TRs[I-1] := TR;
  end;
  Sum := 0;
  for I := 0 to P-1 do Sum := Sum + TRs[I];
  Result := Sum / P;
  for I := P to High(TRs) do Result := (Result*(P-1)+TRs[I])/P;
end;

class function TTechnicalAnalysis.FullAnalysis(const C: TCandleArray; Price24hAgo, Vol24h: Double): TTechnicalIndicators;
begin
  FillChar(Result, SizeOf(Result), 0);
  if Length(C) < 2 then Exit;
  Result.CurrentPrice := C[High(C)].Close;
  Result.Volume24h := Vol24h;
  if Price24hAgo > 0 then
    Result.PriceChange24h := ((Result.CurrentPrice - Price24hAgo) / Price24hAgo) * 100;
  Result.RSI := RSI(C);
  Result.MACD := MACD(C, Result.MACDSignal, Result.MACDHistogram);
  Result.SMA20 := SMA(C, 20);
  Result.SMA50 := SMA(C, 50);
  Result.EMA12 := EMA(C, 12);
  Result.EMA26 := EMA(C, 26);
  BollingerBands(C, Result.BollingerUpper, Result.BollingerMiddle, Result.BollingerLower);
  Result.ATR := ATR(C);
end;

class function TTechnicalAnalysis.TechnicalScore(const I: TTechnicalIndicators): Double;
var S: Double;
begin
  S := 0;
  if I.RSI < 30 then S := S + 30 else if I.RSI > 70 then S := S - 30
  else if I.RSI < 45 then S := S + 10 else if I.RSI > 55 then S := S - 10;
  if I.MACDHistogram > 0 then S := S + 15 else S := S - 15;
  if I.MACD > I.MACDSignal then S := S + 10 else S := S - 10;
  if I.CurrentPrice > I.SMA20 then S := S + 10 else S := S - 10;
  if I.SMA20 > I.SMA50 then S := S + 15 else S := S - 15;
  if I.BollingerLower > 0 then begin
    if I.CurrentPrice <= I.BollingerLower then S := S + 20
    else if I.CurrentPrice >= I.BollingerUpper then S := S - 20;
  end;
  Result := Max(-100, Min(100, S));
end;

class function TTechnicalAnalysis.TechnicalScoreEx(const I: TTechnicalIndicators; out Breakdown: string): Double;
var S: Double; Parts: TArray<string>;

  procedure Add(const Desc: string; Points: Double);
  begin
    S := S + Points;
    SetLength(Parts, Length(Parts) + 1);
    if Points >= 0 then
      Parts[High(Parts)] := Format('%s: +%.0f', [Desc, Points])
    else
      Parts[High(Parts)] := Format('%s: %.0f', [Desc, Points]);
  end;

begin
  S := 0;
  SetLength(Parts, 0);

  if I.RSI < 30 then Add(Format('RSI=%.1f (sobrevendido)', [I.RSI]), 30)
  else if I.RSI > 70 then Add(Format('RSI=%.1f (sobrecomprado)', [I.RSI]), -30)
  else if I.RSI < 45 then Add(Format('RSI=%.1f (tendencia alta)', [I.RSI]), 10)
  else if I.RSI > 55 then Add(Format('RSI=%.1f (tendencia baixa)', [I.RSI]), -10)
  else Add(Format('RSI=%.1f (neutro)', [I.RSI]), 0);

  if I.MACDHistogram > 0 then Add('MACD Hist>0 (alta)', 15)
  else Add('MACD Hist<0 (baixa)', -15);

  if I.MACD > I.MACDSignal then Add('MACD>Signal (alta)', 10)
  else Add('MACD<Signal (baixa)', -10);

  if I.CurrentPrice > I.SMA20 then Add('Preco>SMA20 (alta)', 10)
  else Add('Preco<SMA20 (baixa)', -10);

  if I.SMA20 > I.SMA50 then Add('SMA20>SMA50 (alta)', 15)
  else Add('SMA20<SMA50 (baixa)', -15);

  if I.BollingerLower > 0 then
  begin
    if I.CurrentPrice <= I.BollingerLower then Add('Preco<=BollingerInf (bounce)', 20)
    else if I.CurrentPrice >= I.BollingerUpper then Add('Preco>=BollingerSup (topo)', -20)
    else Add('Preco entre Bollinger (neutro)', 0);
  end;

  Result := Max(-100, Min(100, S));
  Breakdown := '';
  var I2: Integer;
  for I2 := 0 to High(Parts) do
  begin
    if Breakdown <> '' then Breakdown := Breakdown + ' | ';
    Breakdown := Breakdown + Parts[I2];
  end;
  Breakdown := Format('Score=%.0f [%s]', [Result, Breakdown]);
end;

end.
