using System;
using System.Collections;
using System.Collections.Generic;
using System.Diagnostics;
using System.Drawing;
using System.IO;
using System.Reflection;
using System.Text;
using System.Threading.Tasks;
using System.Web.Script.Serialization;
using System.Windows.Forms;

internal sealed class GitPanel : UserControl {
 readonly string state; readonly Func<string> parent; readonly Action<bool> lockLauncher;
 readonly JavaScriptSerializer json=new JavaScriptSerializer {MaxJsonLength=16*1024*1024};
 readonly ComboBox repo=new ComboBox(); readonly TextBox destination=new TextBox(), branch=new TextBox(), author=new TextBox(), email=new TextBox(), message=new TextBox(), preview=new TextBox();
 readonly Label accountLabel=new Label(), branchLabel=new Label(), status=new Label();
 readonly ListView files=new ListView(); readonly TableLayoutPanel content=new TableLayoutPanel();
 string account="", head="", currentBranch=""; bool loading; int previewGeneration;
 public bool Busy {get;private set;}
 public GitPanel(string stateDirectory,Func<string> installParent,Action<bool> busyCallback) {
  state=stateDirectory; parent=installParent; lockLauncher=busyCallback; Dock=DockStyle.Fill;
  content.Dock=DockStyle.Fill; content.Padding=new Padding(16); content.ColumnCount=1; content.RowCount=9;
  foreach(float h in new float[]{50,62,62,32}) content.RowStyles.Add(new RowStyle(SizeType.Absolute,h));
  content.RowStyles.Add(new RowStyle(SizeType.Percent,100));
  foreach(float h in new float[]{60,62,44,48}) content.RowStyles.Add(new RowStyle(SizeType.Absolute,h));
  Controls.Add(content);
  var accounts=Flow(); accountLabel.Text="GitHub: not signed in"; accountLabel.AutoSize=true; accountLabel.Padding=new Padding(0,8,10,0); accounts.Controls.Add(accountLabel);
  Button(accounts,"Sign in…",SignIn); Button(accounts,"Switch account…",SwitchAccount); Button(accounts,"Refresh account",async delegate {await LoadAccount();}); content.Controls.Add(accounts);
  var destinations=new TableLayoutPanel {Dock=DockStyle.Fill,ColumnCount=2}; destinations.ColumnStyles.Add(new ColumnStyle(SizeType.Percent,30));destinations.ColumnStyles.Add(new ColumnStyle(SizeType.Percent,70));
  repo.DropDownStyle=ComboBoxStyle.DropDownList;repo.Items.AddRange(new object[]{"SWLOR_NWN","SWLOR_Haks"});repo.SelectedIndex=0;
  destinations.Controls.Add(Field("Working repository",repo));destinations.Controls.Add(Field("Publish to (owner/repository)",destination));content.Controls.Add(destinations);
  var branches=Flow();branch.Width=220;branches.Controls.Add(Field("New working branch",branch,230));Button(branches,"Create branch",async delegate {await Call("Branch",new Dictionary<string,object>{{"branch",branch.Text.Trim()}});await RefreshFiles();});Button(branches,"Create my fork",Fork);Button(branches,"Refresh files",RefreshFiles);content.Controls.Add(branches);
  branchLabel.Dock=DockStyle.Fill;branchLabel.Text="Select Refresh files to load the installed repository.";content.Controls.Add(branchLabel);
  var split=new TableLayoutPanel {Dock=DockStyle.Fill,ColumnCount=2};split.ColumnStyles.Add(new ColumnStyle(SizeType.Percent,45));split.ColumnStyles.Add(new ColumnStyle(SizeType.Percent,55));
  files.Dock=DockStyle.Fill;files.View=View.Details;files.CheckBoxes=true;files.FullRowSelect=true;files.MultiSelect=false;files.HideSelection=false;files.Columns.Add("Changed file",290);files.Columns.Add("State",55);
  preview.Dock=DockStyle.Fill;preview.Multiline=true;preview.ReadOnly=true;preview.ScrollBars=ScrollBars.Both;preview.WordWrap=false;preview.Font=new Font("Consolas",9);
  split.Controls.Add(files);split.Controls.Add(preview);content.Controls.Add(split);
  var identity=new TableLayoutPanel {Dock=DockStyle.Fill,ColumnCount=2};identity.ColumnStyles.Add(new ColumnStyle(SizeType.Percent,35));identity.ColumnStyles.Add(new ColumnStyle(SizeType.Percent,65));identity.Controls.Add(Field("Commit author",author));identity.Controls.Add(Field("Author email (GitHub noreply after sign-in)",email));content.Controls.Add(identity);
  content.Controls.Add(Field("Commit message — includes current contents of checked files",message));
  var publish=Flow();Button(publish,"Commit selected files",Commit);Button(publish,"Push to GitHub",Push);Button(publish,"Select all",delegate {foreach(ListViewItem f in files.Items) f.Checked=true;return Task.FromResult(0);});Button(publish,"Select none",delegate {foreach(ListViewItem f in files.Items) f.Checked=false;return Task.FromResult(0);});content.Controls.Add(publish);
  status.Dock=DockStyle.Fill;status.Text="Commits stay local until Push. HAK changes are committed separately.";content.Controls.Add(status);
  repo.SelectedIndexChanged+=async delegate {if(loading||Busy)return;destination.Text=account.Length>0?account+"/"+repo.Text:"";await Guard(RefreshFiles);};
  files.SelectedIndexChanged+=async delegate {if(loading||Busy||files.SelectedItems.Count==0)return;string path=(string)files.SelectedItems[0].Tag;int generation=++previewGeneration;await Guard(async delegate {object result=await Call("Preview",new Dictionary<string,object>{{"path",path}});if(generation==previewGeneration)preview.Text=Convert.ToString(result);});};
 }
 FlowLayoutPanel Flow(){return new FlowLayoutPanel {Dock=DockStyle.Fill,WrapContents=true};}
 Control Field(string label,Control control,int width=0){var p=new TableLayoutPanel {Dock=width==0?DockStyle.Fill:DockStyle.None,ColumnCount=1,RowCount=2,Height=57,Width=width==0?200:width};p.RowStyles.Add(new RowStyle(SizeType.Absolute,23));p.RowStyles.Add(new RowStyle(SizeType.Percent,100));p.Controls.Add(new Label {Text=label,AutoSize=true});control.Dock=DockStyle.Fill;p.Controls.Add(control);return p;}
 void Button(FlowLayoutPanel p,string text,Func<Task> action){var b=new Button {Text=text,AutoSize=true,Height=33,MinimumSize=new Size(90,33),Margin=new Padding(3,6,3,3)};b.Click+=async delegate {await Guard(action);};p.Controls.Add(b);}
 async Task Guard(Func<Task> action){if(Busy)return;Busy=true;content.Enabled=false;lockLauncher(true);try {await action();}catch(Exception ex){status.Text="Operation stopped. See details.";MessageBox.Show(this,ex.Message,"Git & Publish",MessageBoxButtons.OK,MessageBoxIcon.Information);}finally{content.Enabled=true;Busy=false;lockLauncher(false);}}
 string RepoPath {get {string path=Path.Combine(Path.GetFullPath(parent().Trim()),"SWLOR_NWN");return repo.SelectedIndex==1?Path.Combine(path,"SWLOR_Haks"):path;}}
 async Task<object> Call(string action,Dictionary<string,object> values=null){
  var request=values??new Dictionary<string,object>();request["action"]=action;request["state"]=state;request["repo"]=RepoPath;
  string payload=json.Serialize(request);status.Text="Working: "+action+"…";
  return await Task.Run<object>(delegate {
   string dir=Path.Combine(state,"git-jobs",Guid.NewGuid().ToString("N"));Directory.CreateDirectory(dir);
   try {
    foreach(string name in new[]{"Backend.ps1","GitBackend.ps1"})using(var input=Assembly.GetExecutingAssembly().GetManifestResourceStream(name))using(var output=File.Create(Path.Combine(dir,name)))input.CopyTo(output);
    string requestFile=Path.Combine(dir,"request.json"),resultFile=Path.Combine(dir,"result.json");File.WriteAllText(requestFile,payload,new UTF8Encoding(false));
    string command="& '"+Path.Combine(dir,"GitBackend.ps1").Replace("'","''")+"' -RequestFile '"+requestFile.Replace("'","''")+"' -ResultFile '"+resultFile.Replace("'","''")+"'";
    var si=new ProcessStartInfo(Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.System),@"WindowsPowerShell\v1.0\powershell.exe"),"-NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -EncodedCommand "+Convert.ToBase64String(Encoding.Unicode.GetBytes(command))){UseShellExecute=false,CreateNoWindow=true,RedirectStandardOutput=true,RedirectStandardError=true};
    using(var p=Process.Start(si)){var stdout=p.StandardOutput.ReadToEndAsync();var stderr=p.StandardError.ReadToEndAsync();p.WaitForExit();Task.WaitAll(stdout,stderr);if(!File.Exists(resultFile))throw new IOException("Git operation failed. "+stderr.Result);}
    var response=json.Deserialize<Dictionary<string,object>>(File.ReadAllText(resultFile));if(!(bool)response["ok"])throw new IOException(Convert.ToString(response["error"]));return response["data"];
   }finally {try {Directory.Delete(dir,true);}catch{}}
  });
 }
 async Task RefreshFiles(){loading=true;try{var snapshot=(Dictionary<string,object>)await Call("Refresh");currentBranch=Convert.ToString(snapshot["branch"]);head=Convert.ToString(snapshot["head"]);files.Items.Clear();preview.Clear();foreach(var value in (IEnumerable)snapshot["files"]){var f=(Dictionary<string,object>)value;var item=new ListViewItem(Convert.ToString(f["path"]));item.Tag=f["path"];item.SubItems.Add(Convert.ToString(f["status"]));files.Items.Add(item);}branchLabel.Text="Current branch: "+(currentBranch.Length==0?"detached HEAD — create a branch":currentBranch)+"   |   "+files.Items.Count+" changed files";status.Text="Choose files to commit. Push sends all local commits on the current branch.";}finally{loading=false;}}
 async Task LoadAccount(){var user=(Dictionary<string,object>)await Call("Account");account=Convert.ToString(user["login"]);accountLabel.Text="GitHub: "+account;author.Text=account;email.Text=Convert.ToString(user["id"])+"+"+account+"@users.noreply.github.com";destination.Text=account+"/"+repo.Text;status.Text="Signed in. Choose your destination repository before pushing.";}
 async Task SignIn(){
  var info=(Dictionary<string,object>)await Call("PrepareAuth");
  var si=new ProcessStartInfo(Convert.ToString(info["gh"]),"auth login --hostname github.com --git-protocol https --web --skip-ssh-key"){UseShellExecute=false};
  si.EnvironmentVariables["GH_CONFIG_DIR"]=Convert.ToString(info["authDirectory"]);
  foreach(string key in new[]{"GH_TOKEN","GITHUB_TOKEN","GH_ENTERPRISE_TOKEN","GITHUB_ENTERPRISE_TOKEN","GH_PROMPT_DISABLED"})si.EnvironmentVariables.Remove(key);
  status.Text="Complete GitHub sign-in in the login window and browser.";
  // This is the user-requested interactive authentication window; no token is read by the launcher.
  await Task.Run(delegate {using(var p=Process.Start(si)){p.WaitForExit();if(p.ExitCode!=0)throw new IOException("GitHub sign-in was cancelled or failed.");}});
  await LoadAccount();
 }
 async Task SwitchAccount(){string user=Prompt("Switch to an account previously signed in with this launcher","GitHub username");if(user==null)return;await Call("SwitchAccount",new Dictionary<string,object>{{"account",user.Trim()}});await LoadAccount();}
 async Task Fork(){await LoadAccount();if(MessageBox.Show(this,"Create a fork of zunath/"+repo.Text+" in GitHub account "+account+"?","Create fork",MessageBoxButtons.OKCancel)!=DialogResult.OK)return;await Call("Fork");await LoadAccount();status.Text="Fork created or already available. The upstream origin is unchanged.";}
 async Task Commit(){var selected=new List<string>();foreach(ListViewItem f in files.CheckedItems)selected.Add((string)f.Tag);if(selected.Count==0)throw new IOException("Check at least one file.");string result=Convert.ToString(await Call("Commit",new Dictionary<string,object>{{"files",selected},{"message",message.Text},{"authorName",author.Text.Trim()},{"authorEmail",email.Text.Trim()}}));await RefreshFiles();status.Text="Committed locally. Use Push to publish.";preview.Text=result;}
 async Task Push(){if(account.Length==0)throw new IOException("Sign in or refresh your GitHub account first.");await RefreshFiles();if(currentBranch.Length==0)throw new IOException("Create a working branch first.");if(MessageBox.Show(this,"Push all local commits on this branch?\n\nAccount: "+account+"\nDestination: "+destination.Text.Trim()+"\nBranch: "+currentBranch+"\nCommit: "+head+"\n\nUncommitted files are not sent.","Publish commits",MessageBoxButtons.OKCancel,MessageBoxIcon.Question)!=DialogResult.OK)return;string result=Convert.ToString(await Call("Push",new Dictionary<string,object>{{"destination",destination.Text.Trim()},{"branch",currentBranch},{"head",head},{"account",account}}));status.Text="Push completed.";preview.Text=result;}
 string Prompt(string title,string label){using(var d=new Form {Text=title,ClientSize=new Size(480,115),StartPosition=FormStartPosition.CenterParent,MinimizeBox=false,MaximizeBox=false,FormBorderStyle=FormBorderStyle.FixedDialog}){var input=new TextBox {Left=16,Top=35,Width=445};d.Controls.Add(new Label {Text=label,Left=16,Top=10,AutoSize=true});d.Controls.Add(input);var ok=new Button {Text="Switch",Left=365,Top=74,DialogResult=DialogResult.OK};d.Controls.Add(ok);d.AcceptButton=ok;return d.ShowDialog(this)==DialogResult.OK?input.Text:null;}}
}
