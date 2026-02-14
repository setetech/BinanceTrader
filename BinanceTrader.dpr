program BinanceTrader;

uses
  Vcl.Forms,
  uMain in 'uMain.pas' {frmMain},
  uTypes in 'uTypes.pas',
  uBinanceAPI in 'uBinanceAPI.pas',
  uTechnicalAnalysis in 'uTechnicalAnalysis.pas',
  uAIEngine in 'uAIEngine.pas',
  uDatabase in 'uDatabase.pas',
  Vcl.Themes,
  Vcl.Styles;

{$R *.res}

begin
  Application.Initialize;

  Application.MainFormOnTaskbar := True;
  TStyleManager.TrySetStyle('Tablet Dark');
  Application.Title := 'Binance Recovery Bot';
  Application.CreateForm(TfrmMain, frmMain);
  Application.Run;
end.
