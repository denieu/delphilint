{
DelphiLint Client for RAD Studio
Copyright (C) 2023 Integrated Application Development

This program is free software: you can redistribute it and/or modify it under
the terms of the GNU Lesser General Public License as published by the Free
Software Foundation, either version 3 of the License, or (at your option) any
later version.

This program is distributed in the hope that it will be useful, but WITHOUT ANY
WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR A
PARTICULAR PURPOSE. See the GNU Lesser General Public License for more details.

You should have received a copy of the GNU General Public License along with
this program. If not, see <https://www.gnu.org/licenses/>.
}
unit DelphiLint.Analyzer;

interface

uses
    DelphiLint.Server
  , DelphiLint.Data
  , System.Generics.Collections
  , DelphiLint.Events
  , System.SyncObjs
  , DelphiLint.ContextTypes
  ;

type
  TAnalyzerImpl = class(TAnalyzer)
  private
    FServer: TLintServer;
    FActiveIssues: TObjectDictionary<string, TObjectList<TLiveIssue>>;
    FFileAnalyses: TDictionary<string, TFileAnalysisHistory>;
    FRules: TObjectDictionary<string, TRule>;
    FCurrentAnalysis: TCurrentAnalysis;
    FOnAnalysisStarted: TEventNotifier<TArray<string>>;
    FOnAnalysisComplete: TEventNotifier<TArray<string>>;
    FOnAnalysisFailed: TEventNotifier<TArray<string>>;
    FServerTerminateEvent: TEvent;
    FServerLock: TMutex;

    procedure OnAnalyzeResult(Issues: TObjectList<TLintIssue>);
    procedure OnAnalyzeError(Message: string);
    procedure OnServerTerminated(Sender: TObject);
    procedure SaveIssues(Issues: TObjectList<TLintIssue>; IssuesHaveMetadata: Boolean = False);
    procedure EnsureServerInited;
    function GetInitedServer: TLintServer;
    function TryRefreshRules: Boolean;
    procedure RecordAnalysis(Path: string; Success: Boolean; IssuesFound: Integer);

    function FilterNonProjectFiles(const InFiles: TArray<string>; const BaseDir: string): TArray<string>;

    procedure AnalyzeFiles(
      const Files: TArray<string>;
      const BaseDir: string;
      const SonarHostUrl: string = '';
      const ProjectKey: string = '';
      const ApiToken: string = '';
      const ProjectPropertiesPath: string = '';
      const DownloadPlugin: Boolean = True);
    procedure AnalyzeFilesWithProjectOptions(const Files: TArray<string>; const ProjectFile: string);

  protected
    function GetOnAnalysisStarted: TEventNotifier<TArray<string>>; override;
    function GetOnAnalysisComplete: TEventNotifier<TArray<string>>; override;
    function GetOnAnalysisFailed: TEventNotifier<TArray<string>>; override;
    function GetCurrentAnalysis: TCurrentAnalysis; override;
    function GetInAnalysis: Boolean; override;
  public
    constructor Create;
    destructor Destroy; override;

    function GetIssues(FileName: string; Line: Integer = -1): TArray<TLiveIssue>; overload; override;

    procedure UpdateIssueLine(FilePath: string; OriginalLine: Integer; NewLine: Integer); override;

    procedure AnalyzeActiveFile; override;
    procedure AnalyzeOpenFiles; override;

    procedure RestartServer; override;

    function GetAnalysisStatus(Path: string): TFileAnalysisStatus; override;
    function TryGetAnalysisHistory(Path: string; out History: TFileAnalysisHistory): Boolean; override;

    function GetRule(RuleKey: string; AllowRefresh: Boolean = True): TRule; override;
  end;

implementation

uses
    System.SysUtils
  , System.Classes
  , System.IOUtils
  , System.StrUtils
  , System.Generics.Defaults
  , System.Hash
  , Vcl.Dialogs
  , ToolsAPI
  , DelphiLint.ProjectOptions
  , DelphiLint.Utils
  , DelphiLint.Settings
  , DelphiLint.Context
  ;

//______________________________________________________________________________________________________________________

procedure TAnalyzerImpl.AnalyzeActiveFile;
var
  ProjectFile: string;
  SourceEditor: IOTASourceEditor;
begin
  if not TryGetProjectFile(ProjectFile) then begin
    TaskMessageDlg(
      'DelphiLint cannot analyze the active file.',
      'There is no open Delphi project.',
      mtWarning,
      [mbOK],
      0);
  end
  else if not TryGetCurrentSourceEditor(SourceEditor) then begin
    TaskMessageDlg(
      'DelphiLint cannot analyze the active file.',
      'There are no open files that can be analyzed.',
      mtWarning,
      [mbOK],
      0);
  end
  else begin
    if LintSettings.ClientSaveBeforeAnalysis then begin
      SourceEditor.Module.Save(False, True);
    end;
    AnalyzeFilesWithProjectOptions([SourceEditor.FileName, ProjectFile], ProjectFile);
    Exit;
  end;
end;

//______________________________________________________________________________________________________________________

procedure TAnalyzerImpl.AnalyzeOpenFiles;
var
  ProjectFile: string;
  Modules: TArray<IOTAModule>;
  Files: TArray<string>;
  Module: IOTAModule;
begin
  if TryGetProjectFile(ProjectFile) then begin
    Modules := DelphiLint.Utils.GetOpenSourceModules;

    if LintSettings.ClientSaveBeforeAnalysis then begin
      for Module in Modules do begin
        try
          Module.Save(False, True);
        except
          on E: Exception do begin
            Log.Info('Module %s could not be saved', [Module.FileName]);
          end;
        end;
      end;
    end;

    Files := TArrayUtils.Map<IOTAModule, string>(
      Modules,
      function(Module: IOTAModule): string
      begin
        Result := Module.FileName;
      end);
    SetLength(Files, Length(Files) + 1);
    Files[Length(Files) - 1] := ProjectFile;

    if Length(Files) = 1 then begin
      TaskMessageDlg(
        'DelphiLint cannot analyze all open files.',
        'There are no open files that can be analyzed.',
        mtWarning,
        [mbOK],
        0);
      Exit;
    end;

    AnalyzeFilesWithProjectOptions(Files, ProjectFile);
  end
  else begin
    TaskMessageDlg(
      'DelphiLint cannot analyze all open files.',
      'There is no open Delphi project.',
      mtWarning,
      [mbOK],
      0);
  end;
end;

//______________________________________________________________________________________________________________________

procedure TAnalyzerImpl.AnalyzeFilesWithProjectOptions(const Files: TArray<string>; const ProjectFile: string);
var
  ProjectOptions: TLintProjectOptions;
  SonarHostUrl: string;
  ProjectKey: string;
  SonarHostToken: string;
begin
  ProjectOptions := TLintProjectOptions.Create(ProjectFile);
  try
    if ProjectOptions.AnalysisConnectedMode then begin
      SonarHostUrl := ProjectOptions.SonarHostUrl;
      ProjectKey := ProjectOptions.SonarHostProjectKey;
      SonarHostToken := ProjectOptions.SonarHostToken;
    end;

    AnalyzeFiles(
      Files,
      IfThen(
        ProjectOptions.AnalysisBaseDir <> '',
        ProjectOptions.AnalysisBaseDirAbsolute,
        TPath.GetDirectoryName(ProjectFile)),
      SonarHostUrl,
      ProjectKey,
      SonarHostToken,
      ProjectOptions.ProjectPropertiesPath,
      ProjectOptions.SonarHostDownloadPlugin
    );
  finally
    FreeAndNil(ProjectOptions);
  end;
end;

//______________________________________________________________________________________________________________________

procedure TAnalyzerImpl.AnalyzeFiles(
  const Files: TArray<string>;
  const BaseDir: string;
  const SonarHostUrl: string = '';
  const ProjectKey: string = '';
  const ApiToken: string = '';
  const ProjectPropertiesPath: string = '';
  const DownloadPlugin: Boolean = True);
var
  Server: TLintServer;
  IncludedFiles: TArray<string>;
begin
  if InAnalysis then begin
    Log.Info('Analysis requested, but we are currently in analysis - ignoring');
    Exit;
  end;

  IncludedFiles := FilterNonProjectFiles(Files, BaseDir);
  FCurrentAnalysis := TCurrentAnalysis.Create(IncludedFiles);
  FOnAnalysisStarted.Notify(IncludedFiles);

  FServerLock.Acquire;
  try
    try
      Server := GetInitedServer;
      Server.Analyze(
        BaseDir,
        IncludedFiles,
        OnAnalyzeResult,
        OnAnalyzeError,
        SonarHostUrl,
        ProjectKey,
        ApiToken,
        ProjectPropertiesPath,
        DownloadPlugin);
    except
      on E: ELintServerError do begin
        TaskMessageDlg('The DelphiLint server encountered an error.', Format('%s.', [E.Message]), mtError, [mbOK], 0);
        Exit;
      end;
    end;
  finally
    FServerLock.Release;
  end;
end;

//______________________________________________________________________________________________________________________

function TAnalyzerImpl.FilterNonProjectFiles(const InFiles: TArray<string>; const BaseDir: string): TArray<string>;
var
  NormalizedBaseDir: string;
  FileName: string;
  OutFiles: TStringList;
begin
  NormalizedBaseDir := NormalizePath(BaseDir);

  OutFiles := TStringList.Create;
  try
    for FileName in InFiles do begin
      if StartsStr(NormalizedBaseDir, NormalizePath(FileName)) then begin
        OutFiles.Add(FileName);
      end
      else begin
        Log.Info('Excluding non-project file %s from analysis', [FileName]);
      end;
    end;

    Result := OutFiles.ToStringArray;
  finally
    FreeAndNil(OutFiles);
  end;
end;


//______________________________________________________________________________________________________________________

constructor TAnalyzerImpl.Create;
begin
  inherited;
  FActiveIssues := TObjectDictionary<string, TObjectList<TLiveIssue>>.Create;
  FCurrentAnalysis := nil;
  FFileAnalyses := TDictionary<string, TFileAnalysisHistory>.Create;
  FOnAnalysisStarted := TEventNotifier<TArray<string>>.Create;
  FOnAnalysisComplete := TEventNotifier<TArray<string>>.Create;
  FOnAnalysisFailed := TEventNotifier<TArray<string>>.Create;
  FRules := TObjectDictionary<string, TRule>.Create;
  FServerLock := TMutex.Create;
  FServer := nil;

  Log.Info('DelphiLint context initialised');
end;

//______________________________________________________________________________________________________________________

destructor TAnalyzerImpl.Destroy;
var
  WaitForTerminate: Boolean;
begin
  WaitForTerminate := False;

  FServerTerminateEvent := TEvent.Create;
  try
    FServerLock.Acquire;
    try
      if Assigned(FServer) then begin
        WaitForTerminate := True;
        FServer.OnTerminate := nil;
        FServer.Terminate;
      end;
    finally
      FServerLock.Release;
    end;

    if WaitForTerminate then begin
      FServerTerminateEvent.WaitFor(1200);
    end;
  finally
    FreeAndNil(FServerTerminateEvent);
  end;

  FreeAndNil(FRules);
  FreeAndNil(FActiveIssues);
  FreeAndNil(FFileAnalyses);
  FreeAndNil(FOnAnalysisStarted);
  FreeAndNil(FOnAnalysisComplete);
  FreeAndNil(FOnAnalysisFailed);
  FreeAndNil(FCurrentAnalysis);
  FreeAndNil(FServerLock);

  inherited;
end;

//______________________________________________________________________________________________________________________

function OrderIssuesByRange(const Left: TLiveIssue; const Right: TLiveIssue): Integer;
begin
  Result := TComparer<Integer>.Default.Compare(Left.OriginalStartLine, Right.OriginalStartLine);
  if Result = 0 then begin
    Result := TComparer<Integer>.Default.Compare(Left.StartLineOffset, Right.StartLineOffset);
  end;
  if Result = 0 then begin
    Result := TComparer<string>.Default.Compare(Left.RuleKey, Right.RuleKey);
  end;
  if Result = 0 then begin
    Result := TComparer<Integer>.Default.Compare(Left.EndLineOffset, Right.EndLineOffset);
  end;
end;

//______________________________________________________________________________________________________________________

function TAnalyzerImpl.GetInAnalysis: Boolean;
begin
  Result := Assigned(FCurrentAnalysis);
end;

//______________________________________________________________________________________________________________________

function TAnalyzerImpl.GetOnAnalysisComplete: TEventNotifier<TArray<string>>;
begin
  Result := FOnAnalysisComplete;
end;

//______________________________________________________________________________________________________________________

function TAnalyzerImpl.GetOnAnalysisFailed: TEventNotifier<TArray<string>>;
begin
  Result := FOnAnalysisFailed;
end;

//______________________________________________________________________________________________________________________

function TAnalyzerImpl.GetOnAnalysisStarted: TEventNotifier<TArray<string>>;
begin
  Result := FOnAnalysisStarted;
end;

//______________________________________________________________________________________________________________________

function TAnalyzerImpl.GetCurrentAnalysis: TCurrentAnalysis;
begin
  Result := FCurrentAnalysis;
end;

//______________________________________________________________________________________________________________________

function TAnalyzerImpl.GetIssues(FileName: string; Line: Integer = -1): TArray<TLiveIssue>;
var
  SanitizedName: string;
  Issue: TLiveIssue;
  ResultList: TList<TLiveIssue>;
begin
  SanitizedName := NormalizePath(FileName);
  if FActiveIssues.ContainsKey(SanitizedName) then begin
    if Line = -1 then begin
      Result := FActiveIssues[SanitizedName].ToArray;
      TArray.Sort<TLiveIssue>(Result, TComparer<TLiveIssue>.Construct(OrderIssuesByRange));
    end
    else begin
      ResultList := TList<TLiveIssue>.Create;
      try
        for Issue in FActiveIssues[SanitizedName] do begin
          if (Line >= Issue.StartLine) and (Line <= Issue.EndLine) then begin
            ResultList.Add(Issue);
          end;
        end;

        ResultList.Sort(TComparer<TLiveIssue>.Construct(OrderIssuesByRange));
        Result := ResultList.ToArray;
      finally
        FreeAndNil(ResultList);
      end;
    end;
  end;
end;

//______________________________________________________________________________________________________________________

procedure TAnalyzerImpl.EnsureServerInited;
begin
  FServerLock.Acquire;
  try
    if not Assigned(FServer) then begin
      FServer := TLintServer.Create;
      FServer.OnTerminate := OnServerTerminated;
      FServer.FreeOnTerminate := True;
    end;
  finally
    FServerLock.Release;
  end;
end;

//______________________________________________________________________________________________________________________

procedure TAnalyzerImpl.OnServerTerminated(Sender: TObject);
begin
  FServerLock.Acquire;
  try
    FServer := nil;
  finally
    FServerLock.Release;
  end;

  if InAnalysis then begin
    OnAnalyzeError('Analysis failed as the server was terminated');
  end;

  if Assigned(FServerTerminateEvent) then begin
    FServerTerminateEvent.SetEvent;
  end;
end;

//______________________________________________________________________________________________________________________

function TAnalyzerImpl.GetInitedServer: TLintServer;
begin
  EnsureServerInited;
  Result := FServer;
end;

//______________________________________________________________________________________________________________________

function TAnalyzerImpl.GetAnalysisStatus(Path: string): TFileAnalysisStatus;
var
  NormalizedPath: string;
  History: TFileAnalysisHistory;
begin
  NormalizedPath := NormalizePath(Path);

  if FFileAnalyses.ContainsKey(NormalizedPath) then begin
    History := FFileAnalyses[NormalizedPath];
    if THashMD5.GetHashStringFromFile(Path) = History.FileHash then begin
      Result := TFileAnalysisStatus.fasUpToDateAnalysis;
    end
    else begin
      Result := TFileAnalysisStatus.fasOutdatedAnalysis;
    end;
  end
  else begin
    Result := TFileAnalysisStatus.fasNeverAnalyzed;
  end;
end;

//______________________________________________________________________________________________________________________

procedure TAnalyzerImpl.OnAnalyzeError(Message: string);
begin
  TThread.Queue(
    TThread.Current,
    procedure
    var
      Path: string;
      Paths: TArray<string>;
    begin
      for Path in FCurrentAnalysis.Paths do begin
        RecordAnalysis(Path, False, 0);
      end;

      Paths := FCurrentAnalysis.Paths;
      FreeAndNil(FCurrentAnalysis);
      FOnAnalysisFailed.Notify(Paths);

      TaskMessageDlg('DelphiLint encountered a problem during analysis.', Message + '.', mtWarning, [mbOK], 0);
    end);
end;

//______________________________________________________________________________________________________________________

procedure TAnalyzerImpl.OnAnalyzeResult(Issues: TObjectList<TLintIssue>);
var
  HasMetadata: Boolean;
  ProjectFile: string;
  ProjectOptions: TLintProjectOptions;
begin
  HasMetadata := False;
  if TryGetProjectFile(ProjectFile) then begin
    try
      ProjectOptions := TLintProjectOptions.Create(ProjectFile);
      HasMetadata := ProjectOptions.AnalysisConnectedMode;
    finally
      FreeAndNil(ProjectOptions);
    end;
  end;

  TThread.Queue(
    TThread.Current,
    procedure
    var
      Paths: TArray<string>;
    begin
      try
        SaveIssues(Issues, HasMetadata);
      finally
        FreeAndNil(Issues);
      end;

      Paths := FCurrentAnalysis.Paths;
      FreeAndNil(FCurrentAnalysis);
      FOnAnalysisComplete.Notify(Paths);
    end);
end;

//______________________________________________________________________________________________________________________

procedure TAnalyzerImpl.RecordAnalysis(Path: string; Success: Boolean; IssuesFound: Integer);
var
  SanitizedPath: string;
  History: TFileAnalysisHistory;
begin
  History.AnalysisTime := Now;
  History.Success := Success;
  History.IssuesFound := IssuesFound;
  History.FileHash := THashMD5.GetHashStringFromFile(Path);

  SanitizedPath := NormalizePath(Path);
  FFileAnalyses.AddOrSetValue(SanitizedPath, History);

  Log.Info(
    'Analysis recorded for %s at %s, (%s, %d issues found)',
    [
      Path,
      FormatDateTime('hh:nn:ss', History.AnalysisTime),
      IfThen(Success, 'successful', 'failure'),
      IssuesFound
    ]);
end;

//______________________________________________________________________________________________________________________

procedure TAnalyzerImpl.SaveIssues(Issues: TObjectList<TLintIssue>; IssuesHaveMetadata: Boolean = False);
var
  Issue: TLintIssue;
  LiveIssue: TLiveIssue;
  SanitizedPath: string;
  NewIssues: TDictionary<string, TObjectList<TLiveIssue>>;
  FileContents: TDictionary<string, TArray<string>>;
  Path: string;
  NewIssuesForFile: TObjectList<TLiveIssue>;
  IssueCount: Integer;
begin
  try
    FileContents := TDictionary<string, TArray<string>>.Create;
    NewIssues := TDictionary<string, TObjectList<TLiveIssue>>.Create;

    // Split issues by file and convert to live issues
    for Issue in Issues do begin
      SanitizedPath := NormalizePath(Issue.FilePath);
      if not NewIssues.ContainsKey(SanitizedPath) then begin
        NewIssues.Add(SanitizedPath, TObjectList<TLiveIssue>.Create);
        // TODO: Improve encoding handling
        FileContents.Add(SanitizedPath, TFile.ReadAllLines(Issue.FilePath, TEncoding.ANSI));
      end;

      LiveIssue := TLiveIssue.Create(Issue, FileContents[SanitizedPath], IssuesHaveMetadata);
      NewIssues[SanitizedPath].Add(LiveIssue);
    end;

    // Process issues per file
    for Path in FCurrentAnalysis.Paths do begin
      SanitizedPath := NormalizePath(Path);

      // Remove current active issues
      if FActiveIssues.ContainsKey(SanitizedPath) then begin
        FActiveIssues.Remove(SanitizedPath);
      end;

      // Add new active issues (if there are any)
      IssueCount := 0;
      if NewIssues.TryGetValue(SanitizedPath, NewIssuesForFile) then begin
        FActiveIssues.Add(SanitizedPath, NewIssuesForFile);
        IssueCount := FActiveIssues[SanitizedPath].Count;
      end;

      // Record analysis
      RecordAnalysis(Path, True, IssueCount);
    end;
  finally
    FreeAndNil(NewIssues);
    FreeAndNil(FileContents);
  end;
end;

//______________________________________________________________________________________________________________________

function TAnalyzerImpl.TryGetAnalysisHistory(Path: string; out History: TFileAnalysisHistory): Boolean;
begin
  Result := FFileAnalyses.TryGetValue(NormalizePath(Path), History);
end;

//______________________________________________________________________________________________________________________

procedure TAnalyzerImpl.UpdateIssueLine(FilePath: string; OriginalLine: Integer; NewLine: Integer);
var
  SanitizedPath: string;
  Issue: TLiveIssue;
  Delta: Integer;
  Index: Integer;
begin
  SanitizedPath := NormalizePath(FilePath);
  Delta := NewLine - OriginalLine;

  if FActiveIssues.ContainsKey(SanitizedPath) then begin
    for Index := 0 to FActiveIssues[SanitizedPath].Count - 1 do begin
      Issue := FActiveIssues[SanitizedPath][Index];

      if Issue.OriginalStartLine = OriginalLine then begin
        if NewLine = -1 then begin
          Issue.Untether;
        end
        else begin
          Issue.LinesMoved := Delta;
        end;
      end;
    end;
  end;
end;

//______________________________________________________________________________________________________________________

function TAnalyzerImpl.TryRefreshRules: Boolean;
var
  Server: TLintServer;
  ProjectFile: string;
  ProjectOptions: TLintProjectOptions;
  RulesRetrieved: TEvent;
  TimedOut: Boolean;
  SonarHostUrl: string;
  ProjectKey: string;
  SonarHostToken: string;
  DownloadPlugin: Boolean;
begin
  Log.Info('Refreshing ruleset');
  Result := False;

  if not TryGetProjectFile(ProjectFile) then begin
    Log.Info('Not in a project, aborting refresh');
    Exit;
  end;

  try
    RulesRetrieved := TEvent.Create;
    ProjectOptions := TLintProjectOptions.Create(ProjectFile);
    TimedOut := False;

    DownloadPlugin := False;
    if ProjectOptions.AnalysisConnectedMode then begin
      SonarHostUrl := ProjectOptions.SonarHostUrl;
      ProjectKey := ProjectOptions.SonarHostProjectKey;
      SonarHostToken := ProjectOptions.SonarHostToken;
      DownloadPlugin := ProjectOptions.SonarHostDownloadPlugin;
    end;

    FServerLock.Acquire;
    try
      try
        Server := GetInitedServer;
      except
        on E: ELintServerError do begin
          TaskMessageDlg('The DelphiLint server encountered an error.', Format('%s.', [E.Message]), mtError, [mbOK], 0);
          Exit;
        end;
      end;

      Server.RetrieveRules(
        SonarHostUrl,
        ProjectKey,
        procedure(Rules: TObjectDictionary<string, TRule>)
        begin
          if not TimedOut then begin
            // The main thread is blocked waiting for this, so FRules is guaranteed not to be accessed.
            // If FRules is ever accessed by a third thread a mutex will be required.
            FreeAndNil(FRules);
            FRules := Rules;
            RulesRetrieved.SetEvent;
            Log.Info('Retrieved %d rules', [FRules.Count]);
          end
          else begin
            Log.Info('Server retrieved rules after timeout had expired');
          end;
        end,
        procedure(ErrorMsg: string) begin
          if not TimedOut then begin
            RulesRetrieved.SetEvent;
            Log.Info('Error retrieving latest rules: ' + ErrorMsg);
          end
          else begin
            Log.Info('Server rule retrieval returned error after timeout had expired');
          end;
        end,
        SonarHostToken,
        DownloadPlugin);
    finally
      FServerLock.Release;
    end;

    if RulesRetrieved.WaitFor(3000) = TWaitResult.wrSignaled then begin
      Result := True;
    end else begin
      TimedOut := True;
      Result := False;
      Log.Info('Rule retrieval timed out');
    end;
  finally
    FreeAndNil(ProjectOptions);
    FreeAndNil(RulesRetrieved);
  end;
end;

//______________________________________________________________________________________________________________________

procedure TAnalyzerImpl.RestartServer;
var
  WaitForTerminate: Boolean;
begin
  WaitForTerminate := False;
  FServerTerminateEvent := TEvent.Create;
  try
    FServerLock.Acquire;
    try
      if Assigned(FServer) then begin
        WaitForTerminate := True;
        FServer.Terminate;
      end;
    finally
      FServerLock.Release;
    end;

    if WaitForTerminate and (FServerTerminateEvent.WaitFor(3000) <> wrSignaled) then begin
      TaskMessageDlg(
        'The DelphiLint server could not be terminated gracefully.',
        'The DelphiLint server was unresponsive to a termination request, so it was forcibly terminated.',
        mtWarning,
        [mbOK],
        0);
    end;
  finally
    FreeAndNil(FServerTerminateEvent);
  end;

  if InAnalysis then begin
    OnAnalyzeError('Analysis failed because the server was restarted');
  end;

  try
    EnsureServerInited;
    MessageDlg('The DelphiLint server has been restarted.', mtInformation, [mbOK], 0);
  except
    on E: ELintServerError do begin
      TaskMessageDlg(
        'The DelphiLint server encountered a problem while restarting.',
        Format('%s.', [E.Message]),
        mtError,
        [mbOK],
        0);
    end;
  end;
end;

//______________________________________________________________________________________________________________________

function TAnalyzerImpl.GetRule(RuleKey: string; AllowRefresh: Boolean = True): TRule;
begin
  Result := nil;

  if FRules.ContainsKey(RuleKey) then begin
    Result := FRules[RuleKey];
  end
  else if AllowRefresh then begin
    Log.Info('No rule with rulekey %s found, refreshing ruleset', [RuleKey]);
    if TryRefreshRules then begin
      Result := GetRule(RuleKey, False);
    end;
  end;
end;

end.
