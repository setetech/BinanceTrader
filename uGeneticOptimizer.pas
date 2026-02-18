unit uGeneticOptimizer;

interface

uses
  System.SysUtils, System.Math, System.Classes,
  System.Generics.Collections, System.Generics.Defaults,
  uTypes, uTechnicalAnalysis;

type
  TGAChromosome = record
    // Level 1 - Score weights
    wRSI:        Double;  // 0-50
    wMACDHist:   Double;  // 0-30
    wMACDSignal: Double;  // 0-20
    wPriceSMA:   Double;  // 0-20
    wSMATrend:   Double;  // 0-30
    wBollinger:  Double;  // 0-40
    // Level 2 - Trading parameters
    StopLoss:      Double;  // 0.5-15.0 (%)
    TakeProfit:    Double;  // 1.0-25.0 (%)
    MinScore:      Double;  // 10-60
    RSIOversold:   Double;  // 20-40
    RSIOverbought: Double;  // 60-80
  end;

  TBacktestResult = record
    NetProfit:      Double;
    NumTrades:      Integer;
    MaxDrawdown:    Double;
    WinRate:        Double;
    AvgTradeProfit: Double;
    TotalReturn:    Double;
  end;

  TGAIndividual = record
    Chromosome: TGAChromosome;
    Fitness:    Double;
    Result:     TBacktestResult;
  end;

  TGAProgressEvent = TProc<Integer, Integer, Double, TBacktestResult>;

  TGeneticOptimizer = class
  private
    FPopSize:        Integer;
    FGenerations:    Integer;
    FMutationRate:   Double;
    FElitismPct:     Double;
    FTournamentSize: Integer;
    FPopulation:     TArray<TGAIndividual>;
    FBestIndividual: TGAIndividual;
    FCancelled:      Boolean;

    FSymbols:    TArray<string>;
    FCandleData: TArray<TCandleArray>;
    FPrecomputed: TArray<TArray<TTechnicalIndicators>>;

    FOnProgress: TGAProgressEvent;

    function  RandomChromosome: TGAChromosome;
    procedure InitPopulation;
    function  TournamentSelect: TGAIndividual;
    function  Crossover(const A, B: TGAChromosome): TGAChromosome;
    function  Mutate(const C: TGAChromosome): TGAChromosome;
    function  ClampGene(Value, MinVal, MaxVal: Double): Double;

    function  ScoreWithWeights(const Ind: TTechnicalIndicators;
                const W: TGAChromosome): Double;
    procedure PrecomputeIndicators;
    function  BacktestSymbol(SymbolIdx: Integer;
                const Chrom: TGAChromosome): TBacktestResult;
    function  BacktestAll(const Chrom: TGAChromosome): TBacktestResult;
    function  CalculateFitness(const R: TBacktestResult): Double;

    procedure EvaluatePopulation;
    procedure SortPopulation;
    procedure NextGeneration;
  public
    constructor Create;

    procedure RunOptimization(
      const ASymbols: TArray<string>;
      const ACandleData: TArray<TCandleArray>);
    procedure Cancel;

    property PopulationSize: Integer read FPopSize write FPopSize;
    property Generations: Integer read FGenerations write FGenerations;
    property MutationRate: Double read FMutationRate write FMutationRate;
    property ElitismPercent: Double read FElitismPct write FElitismPct;

    property BestParams: TGAChromosome read FBestIndividual.Chromosome;
    property BestResult: TBacktestResult read FBestIndividual.Result;
    property BestFitness: Double read FBestIndividual.Fitness;
    property Cancelled: Boolean read FCancelled;

    property OnProgress: TGAProgressEvent read FOnProgress write FOnProgress;
  end;

const
  GENE_COUNT = 11;
  WARMUP_CANDLES = 50;

  GENE_MIN: array[0..GENE_COUNT-1] of Double =
    (0, 0, 0, 0, 0, 0,   0.5, 1.0, 10, 20, 60);
  GENE_MAX: array[0..GENE_COUNT-1] of Double =
    (50, 30, 20, 20, 30, 40,  15.0, 25.0, 60, 40, 80);

implementation

{ Helpers: access chromosome genes by index }

function GetGene(const C: TGAChromosome; Idx: Integer): Double; inline;
begin
  Result := PDouble(PByte(@C) + Idx * SizeOf(Double))^;
end;

procedure SetGene(var C: TGAChromosome; Idx: Integer; Value: Double); inline;
begin
  PDouble(PByte(@C) + Idx * SizeOf(Double))^ := Value;
end;

{ TGeneticOptimizer }

constructor TGeneticOptimizer.Create;
begin
  inherited;
  FPopSize := 100;
  FGenerations := 50;
  FMutationRate := 0.15;
  FElitismPct := 0.05;
  FTournamentSize := 3;
  FCancelled := False;
  FillChar(FBestIndividual, SizeOf(FBestIndividual), 0);
  FBestIndividual.Fitness := -1E30;
end;

function TGeneticOptimizer.ClampGene(Value, MinVal, MaxVal: Double): Double;
begin
  Result := Max(MinVal, Min(MaxVal, Value));
end;

function TGeneticOptimizer.RandomChromosome: TGAChromosome;
var I: Integer;
begin
  for I := 0 to GENE_COUNT - 1 do
    SetGene(Result, I, GENE_MIN[I] + Random * (GENE_MAX[I] - GENE_MIN[I]));
end;

procedure TGeneticOptimizer.InitPopulation;
var I: Integer;
begin
  SetLength(FPopulation, FPopSize);
  for I := 0 to FPopSize - 1 do
  begin
    FPopulation[I].Chromosome := RandomChromosome;
    FPopulation[I].Fitness := -1E30;
  end;
end;

{ Score with custom weights }

function TGeneticOptimizer.ScoreWithWeights(
  const Ind: TTechnicalIndicators; const W: TGAChromosome): Double;
var
  S, MaxScore, MidRSI: Double;
begin
  S := 0;
  MidRSI := (W.RSIOversold + W.RSIOverbought) / 2;

  // RSI
  if Ind.RSI < W.RSIOversold then
    S := S + W.wRSI
  else if Ind.RSI > W.RSIOverbought then
    S := S - W.wRSI
  else if Ind.RSI < MidRSI - 5 then
    S := S + W.wRSI * 0.33
  else if Ind.RSI > MidRSI + 5 then
    S := S - W.wRSI * 0.33;

  // MACD Histogram
  if Ind.MACDHistogram > 0 then
    S := S + W.wMACDHist
  else
    S := S - W.wMACDHist;

  // MACD > Signal
  if Ind.MACD > Ind.MACDSignal then
    S := S + W.wMACDSignal
  else
    S := S - W.wMACDSignal;

  // Price vs SMA20
  if (Ind.SMA20 > 0) and (Ind.CurrentPrice > Ind.SMA20) then
    S := S + W.wPriceSMA
  else
    S := S - W.wPriceSMA;

  // SMA20 vs SMA50 (trend)
  if (Ind.SMA50 > 0) and (Ind.SMA20 > Ind.SMA50) then
    S := S + W.wSMATrend
  else
    S := S - W.wSMATrend;

  // Bollinger
  if Ind.BollingerLower > 0 then
  begin
    if Ind.CurrentPrice <= Ind.BollingerLower then
      S := S + W.wBollinger
    else if Ind.CurrentPrice >= Ind.BollingerUpper then
      S := S - W.wBollinger;
  end;

  // Normalize to -100..+100
  MaxScore := W.wRSI + W.wMACDHist + W.wMACDSignal +
              W.wPriceSMA + W.wSMATrend + W.wBollinger;
  if MaxScore > 0 then
    Result := (S / MaxScore) * 100
  else
    Result := 0;

  Result := Max(-100, Min(100, Result));
end;

{ Pre-compute indicators }

procedure TGeneticOptimizer.PrecomputeIndicators;
var
  S, I: Integer;
  SubCandles: TCandleArray;
begin
  SetLength(FPrecomputed, Length(FCandleData));
  for S := 0 to High(FCandleData) do
  begin
    SetLength(FPrecomputed[S], Length(FCandleData[S]));
    for I := WARMUP_CANDLES to High(FCandleData[S]) do
    begin
      if FCancelled then Exit;
      SetLength(SubCandles, I + 1);
      Move(FCandleData[S][0], SubCandles[0], (I + 1) * SizeOf(TCandle));
      FPrecomputed[S][I] := TTechnicalAnalysis.FullAnalysis(SubCandles);
    end;
  end;
end;

{ Backtesting }

function TGeneticOptimizer.BacktestSymbol(SymbolIdx: Integer;
  const Chrom: TGAChromosome): TBacktestResult;
var
  I, Wins, Losses: Integer;
  Score, CurrentPrice, ChangePercent, TradeProfit: Double;
  InPosition: Boolean;
  EntryPrice, Balance, Peak, Drawdown, MaxDD, TotalTP: Double;
  Candles: TCandleArray;
begin
  FillChar(Result, SizeOf(Result), 0);
  Candles := FCandleData[SymbolIdx];
  if Length(Candles) < WARMUP_CANDLES + 10 then Exit;

  Balance := 10000.0;
  Peak := Balance;
  MaxDD := 0;
  InPosition := False;
  EntryPrice := 0;
  Wins := 0;
  Losses := 0;
  TotalTP := 0;

  for I := WARMUP_CANDLES to High(Candles) do
  begin
    Score := ScoreWithWeights(FPrecomputed[SymbolIdx][I], Chrom);
    CurrentPrice := Candles[I].Close;

    if not InPosition then
    begin
      if Score > Chrom.MinScore then
      begin
        InPosition := True;
        EntryPrice := CurrentPrice;
      end;
    end
    else
    begin
      ChangePercent := ((CurrentPrice - EntryPrice) / EntryPrice) * 100;

      if ChangePercent <= -Chrom.StopLoss then
      begin
        TradeProfit := -Chrom.StopLoss;
        Balance := Balance * (1 + TradeProfit / 100);
        InPosition := False;
        Inc(Losses);
        TotalTP := TotalTP + TradeProfit;
        Inc(Result.NumTrades);
      end
      else if ChangePercent >= Chrom.TakeProfit then
      begin
        TradeProfit := Chrom.TakeProfit;
        Balance := Balance * (1 + TradeProfit / 100);
        InPosition := False;
        Inc(Wins);
        TotalTP := TotalTP + TradeProfit;
        Inc(Result.NumTrades);
      end
      else if Score < -Chrom.MinScore then
      begin
        TradeProfit := ChangePercent;
        Balance := Balance * (1 + TradeProfit / 100);
        InPosition := False;
        if TradeProfit > 0 then Inc(Wins) else Inc(Losses);
        TotalTP := TotalTP + TradeProfit;
        Inc(Result.NumTrades);
      end;
    end;

    if Balance > Peak then Peak := Balance;
    Drawdown := ((Peak - Balance) / Peak) * 100;
    if Drawdown > MaxDD then MaxDD := Drawdown;
  end;

  // Force close any open position
  if InPosition then
  begin
    CurrentPrice := Candles[High(Candles)].Close;
    ChangePercent := ((CurrentPrice - EntryPrice) / EntryPrice) * 100;
    Balance := Balance * (1 + ChangePercent / 100);
    if ChangePercent > 0 then Inc(Wins) else Inc(Losses);
    TotalTP := TotalTP + ChangePercent;
    Inc(Result.NumTrades);

    if Balance > Peak then Peak := Balance;
    Drawdown := ((Peak - Balance) / Peak) * 100;
    if Drawdown > MaxDD then MaxDD := Drawdown;
  end;

  Result.NetProfit := ((Balance - 10000.0) / 10000.0) * 100;
  Result.MaxDrawdown := MaxDD;
  Result.TotalReturn := Balance / 10000.0;
  if Result.NumTrades > 0 then
  begin
    Result.WinRate := (Wins / Result.NumTrades) * 100;
    Result.AvgTradeProfit := TotalTP / Result.NumTrades;
  end;
end;

function TGeneticOptimizer.BacktestAll(const Chrom: TGAChromosome): TBacktestResult;
var
  S, ValidSymbols: Integer;
  SymResult: TBacktestResult;
  TotalProfit, TotalMaxDD, TotalTrades, TotalWinRate: Double;
begin
  FillChar(Result, SizeOf(Result), 0);
  TotalProfit := 0;
  TotalMaxDD := 0;
  TotalTrades := 0;
  TotalWinRate := 0;
  ValidSymbols := 0;

  for S := 0 to High(FCandleData) do
  begin
    SymResult := BacktestSymbol(S, Chrom);
    if SymResult.NumTrades > 0 then
    begin
      TotalProfit := TotalProfit + SymResult.NetProfit;
      if SymResult.MaxDrawdown > TotalMaxDD then
        TotalMaxDD := SymResult.MaxDrawdown;
      TotalTrades := TotalTrades + SymResult.NumTrades;
      TotalWinRate := TotalWinRate + SymResult.WinRate;
      Inc(ValidSymbols);
    end;
  end;

  if ValidSymbols > 0 then
  begin
    Result.NetProfit := TotalProfit / ValidSymbols;
    Result.MaxDrawdown := TotalMaxDD;
    Result.NumTrades := Round(TotalTrades);
    Result.WinRate := TotalWinRate / ValidSymbols;
    Result.TotalReturn := 1 + Result.NetProfit / 100;
    if Result.NumTrades > 0 then
      Result.AvgTradeProfit := Result.NetProfit / Result.NumTrades;
  end;
end;

function TGeneticOptimizer.CalculateFitness(const R: TBacktestResult): Double;
begin
  if R.NumTrades = 0 then
  begin
    Result := -1E10;
    Exit;
  end;

  Result := R.NetProfit * (1 - R.MaxDrawdown / 100) * Sqrt(R.NumTrades);

  if R.NetProfit < 0 then
    Result := Result * 2;
end;

{ GA operations }

function TGeneticOptimizer.TournamentSelect: TGAIndividual;
var
  I, Idx, BestIdx: Integer;
begin
  BestIdx := Random(FPopSize);
  for I := 1 to FTournamentSize - 1 do
  begin
    Idx := Random(FPopSize);
    if FPopulation[Idx].Fitness > FPopulation[BestIdx].Fitness then
      BestIdx := Idx;
  end;
  Result := FPopulation[BestIdx];
end;

function TGeneticOptimizer.Crossover(const A, B: TGAChromosome): TGAChromosome;
var I: Integer;
begin
  for I := 0 to GENE_COUNT - 1 do
  begin
    if Random < 0.5 then
      SetGene(Result, I, GetGene(A, I))
    else
      SetGene(Result, I, GetGene(B, I));
  end;
end;

function TGeneticOptimizer.Mutate(const C: TGAChromosome): TGAChromosome;
var
  I: Integer;
  GeneVal, Range, Sigma, NewVal: Double;
begin
  Result := C;
  for I := 0 to GENE_COUNT - 1 do
  begin
    if Random < FMutationRate then
    begin
      GeneVal := GetGene(Result, I);
      Range := GENE_MAX[I] - GENE_MIN[I];
      Sigma := Range * 0.20;
      NewVal := GeneVal + Sigma * (Random + Random + Random - 1.5) * 0.8165;
      NewVal := ClampGene(NewVal, GENE_MIN[I], GENE_MAX[I]);
      SetGene(Result, I, NewVal);
    end;
  end;
end;

procedure TGeneticOptimizer.EvaluatePopulation;
var I: Integer;
begin
  for I := 0 to High(FPopulation) do
  begin
    if FCancelled then Exit;
    FPopulation[I].Result := BacktestAll(FPopulation[I].Chromosome);
    FPopulation[I].Fitness := CalculateFitness(FPopulation[I].Result);
  end;
end;

procedure TGeneticOptimizer.SortPopulation;
begin
  TArray.Sort<TGAIndividual>(FPopulation,
    TComparer<TGAIndividual>.Construct(
      function(const A, B: TGAIndividual): Integer
      begin
        if A.Fitness > B.Fitness then Result := -1
        else if A.Fitness < B.Fitness then Result := 1
        else Result := 0;
      end
    ));
end;

procedure TGeneticOptimizer.NextGeneration;
var
  NewPop: TArray<TGAIndividual>;
  EliteCount, I: Integer;
  ParentA, ParentB: TGAIndividual;
  Child: TGAChromosome;
begin
  EliteCount := Max(1, Round(FPopSize * FElitismPct));
  SetLength(NewPop, FPopSize);

  // Elitism
  for I := 0 to EliteCount - 1 do
    NewPop[I] := FPopulation[I];

  // Offspring
  for I := EliteCount to FPopSize - 1 do
  begin
    ParentA := TournamentSelect;
    ParentB := TournamentSelect;
    Child := Crossover(ParentA.Chromosome, ParentB.Chromosome);
    Child := Mutate(Child);
    NewPop[I].Chromosome := Child;
    NewPop[I].Fitness := -1E30;
  end;

  FPopulation := NewPop;
end;

{ Main optimization loop }

procedure TGeneticOptimizer.RunOptimization(
  const ASymbols: TArray<string>;
  const ACandleData: TArray<TCandleArray>);
var
  Gen: Integer;
begin
  FCancelled := False;
  FSymbols := ASymbols;
  FCandleData := ACandleData;
  FBestIndividual.Fitness := -1E30;

  PrecomputeIndicators;
  if FCancelled then Exit;

  Randomize;
  InitPopulation;

  for Gen := 0 to FGenerations - 1 do
  begin
    if FCancelled then Exit;

    EvaluatePopulation;
    if FCancelled then Exit;

    SortPopulation;

    if FPopulation[0].Fitness > FBestIndividual.Fitness then
      FBestIndividual := FPopulation[0];

    if Assigned(FOnProgress) then
      FOnProgress(Gen + 1, FGenerations, FBestIndividual.Fitness, FBestIndividual.Result);

    if Gen < FGenerations - 1 then
      NextGeneration;
  end;
end;

procedure TGeneticOptimizer.Cancel;
begin
  FCancelled := True;
end;

end.
