unit DelphiLint.OptionsForm;

interface

uses
  Winapi.Windows, Winapi.Messages, System.SysUtils, System.Variants, System.Classes, Vcl.Graphics,
  Vcl.Controls, Vcl.Forms, Vcl.Dialogs, Vcl.StdCtrls, Vcl.Mask, Vcl.ExtCtrls, DelphiLint.ProjectOptions;

type
  TLintOptionsForm = class(TForm)
    GroupBox1: TGroupBox;
    SonarHostUrlEdit: TLabeledEdit;
    SonarHostTokenEdit: TLabeledEdit;
    GroupBox2: TGroupBox;
    ProjectKeyEdit: TLabeledEdit;
    ProjectBaseDirEdit: TLabeledEdit;
    ProjectNameLabel: TLabel;
    CreateTokenButton: TButton;
    procedure ProjectBaseDirEditChange(Sender: TObject);
    procedure SonarHostUrlEditChange(Sender: TObject);
    procedure ProjectKeyEditChange(Sender: TObject);
    procedure SonarHostTokenEditChange(Sender: TObject);
    procedure FormCreate(Sender: TObject);
    procedure FormShow(Sender: TObject);
    procedure CreateTokenButtonClick(Sender: TObject);
  private
    FProjectOptions: TLintProjectOptions;
    FProjectFile: string;

    function GetCreateTokenUrl(BaseUrl: string): string;
    function IsUrl(Val: string): Boolean;

    procedure UpdateControls;
    procedure UpdateCreateTokenButton;
  public
    procedure RefreshOptions;
  end;

implementation

{$R *.dfm}

uses
    DelphiLint.Utils
  , System.IOUtils
  , Winapi.ShellAPI
  , System.NetEncoding
  , System.StrUtils
  ;

//______________________________________________________________________________________________________________________

procedure TLintOptionsForm.FormCreate(Sender: TObject);
begin
  RefreshOptions;
end;

//______________________________________________________________________________________________________________________

procedure TLintOptionsForm.UpdateControls;
var
  ProjectName: string;
begin
  if Assigned(FProjectOptions) then begin
    SonarHostUrlEdit.Text := FProjectOptions.SonarHostUrl;
    SonarHostTokenEdit.Text := FProjectOptions.SonarHostToken;
    ProjectKeyEdit.Text := FProjectOptions.ProjectKey;
    ProjectBaseDirEdit.Text := FProjectOptions.ProjectBaseDir;

    ProjectName := TPath.GetFileNameWithoutExtension(FProjectFile);
    ProjectNameLabel.Caption := ProjectName;
    Caption := 'DelphiLint Project Options - ' + ProjectName;
  end
  else begin
    SonarHostUrlEdit.Text := '';
    SonarHostTokenEdit.Text := '';
    ProjectKeyEdit.Text := '';
    ProjectBaseDirEdit.Text := '';
    ProjectNameLabel.Caption := 'No project selected';
    Caption := 'DelphiLint Project Options - no project selected';
  end;

  UpdateCreateTokenButton;
end;

//______________________________________________________________________________________________________________________

procedure TLintOptionsForm.RefreshOptions;
var
  ProjectFile: string;
begin

  if TryGetProjectFile(ProjectFile) then begin
    if not Assigned(FProjectOptions) or (FProjectFile <> ProjectFile) then begin
      FreeAndNil(FProjectOptions);
      FProjectOptions := TLintProjectOptions.Create(ProjectFile);
      FProjectFile := ProjectFile;
    end;
  end
  else begin
    FreeAndNil(FProjectOptions);
    FProjectFile := '';
  end;

  UpdateControls;
end;

//______________________________________________________________________________________________________________________

procedure TLintOptionsForm.FormShow(Sender: TObject);
begin
  RefreshOptions;
end;

//______________________________________________________________________________________________________________________

procedure TLintOptionsForm.ProjectBaseDirEditChange(Sender: TObject);
begin
  if Assigned(FProjectOptions) then begin
    FProjectOptions.ProjectBaseDir := ProjectBaseDirEdit.Text;
  end;
end;

//______________________________________________________________________________________________________________________

procedure TLintOptionsForm.SonarHostTokenEditChange(Sender: TObject);
begin
  if Assigned(FProjectOptions) then begin
    FProjectOptions.SonarHostToken := SonarHostTokenEdit.Text;
    UpdateCreateTokenButton;
  end;
end;

//______________________________________________________________________________________________________________________

procedure TLintOptionsForm.SonarHostUrlEditChange(Sender: TObject);
begin
  if Assigned(FProjectOptions) then begin
    FProjectOptions.SonarHostUrl := SonarHostUrlEdit.Text;
    UpdateCreateTokenButton;
  end;
end;

//______________________________________________________________________________________________________________________

procedure TLintOptionsForm.ProjectKeyEditChange(Sender: TObject);
begin
  if Assigned(FProjectOptions) then begin
    FProjectOptions.ProjectKey := ProjectKeyEdit.Text;
  end;
end;

//______________________________________________________________________________________________________________________

procedure TLintOptionsForm.CreateTokenButtonClick(Sender: TObject);
var
  Url: string;
begin
  if Assigned(FProjectOptions) then begin
    Url := FProjectOptions.SonarHostUrl;

    if IsUrl(Url) then begin
      Url := GetCreateTokenUrl(Url);
      ShellExecute(Handle, 'open', PChar(Url), nil, nil, SW_SHOWNORMAL);
    end;
  end;
end;

//______________________________________________________________________________________________________________________

function TLintOptionsForm.GetCreateTokenUrl(BaseUrl: string): string;
begin
  if not EndsStr('/', BaseUrl) then begin
    BaseUrl := BaseUrl + '/';
  end;

  Result := BaseUrl + 'account/security';
end;

//______________________________________________________________________________________________________________________

function TLintOptionsForm.IsUrl(Val: string): Boolean;
begin
  Result := StartsText('http://', Val) or StartsText('https://', Val);
end;

//______________________________________________________________________________________________________________________

procedure TLintOptionsForm.UpdateCreateTokenButton;
begin
  CreateTokenButton.Enabled :=
    Assigned(FProjectOptions)
    and (FProjectOptions.SonarHostToken = '')
    and IsUrl(FProjectOptions.SonarHostUrl);
end;

//______________________________________________________________________________________________________________________

end.
