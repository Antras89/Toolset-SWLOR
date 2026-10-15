using System;
using System.Diagnostics;
using System.Drawing;
using System.IO;
using System.Reflection;
using System.Text;
using System.Windows.Forms;
using System.Security.Principal;
[assembly: AssemblyTitle("SWLOR Toolset Launcher")]
[assembly: AssemblyVersion("1.1.0.0")]
[assembly: System.Runtime.Versioning.TargetFramework(".NETFramework,Version=v4.8")]
internal sealed class Launcher : Form {
 readonly string state=Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),"SWLORLauncher");
 TextBox folder=new TextBox(), log=new TextBox(); ProgressBar progress=new ProgressBar(); Label status=new Label(); FlowLayoutPanel actions=new FlowLayoutPanel(), utilities=new FlowLayoutPanel(); Button browse=new Button(); bool busy;
 [STAThread] static void Main() {
  Application.EnableVisualStyles(); Application.SetCompatibleTextRenderingDefault(false);
  if(!Environment.Is64BitOperatingSystem) { MessageBox.Show("Windows x64 is required."); return; }
  if(new WindowsPrincipal(WindowsIdentity.GetCurrent()).IsInRole(WindowsBuiltInRole.Administrator)) { MessageBox.Show("Please run this launcher as a normal user, not as administrator."); return; }
  Application.Run(new Launcher());
 }
 public Launcher() : this(null) { }
 public Launcher(string stateDirectory) {
  if(stateDirectory!=null) state=stateDirectory;
  Text="SWLOR Toolset Launcher 1.1"; ClientSize=new Size(820,690); MinimumSize=new Size(750,650); Font=new Font("Segoe UI",10); BackColor=Color.FromArgb(244,246,249); StartPosition=FormStartPosition.CenterScreen;
  var layout=new TableLayoutPanel { Dock=DockStyle.Fill, Padding=new Padding(20), ColumnCount=1, RowCount=9 };
  layout.RowStyles.Add(new RowStyle(SizeType.Absolute,50)); layout.RowStyles.Add(new RowStyle(SizeType.Absolute,54)); layout.RowStyles.Add(new RowStyle(SizeType.Absolute,26)); layout.RowStyles.Add(new RowStyle(SizeType.Absolute,40)); layout.RowStyles.Add(new RowStyle(SizeType.Absolute,92)); layout.RowStyles.Add(new RowStyle(SizeType.Absolute,30)); layout.RowStyles.Add(new RowStyle(SizeType.Absolute,26)); layout.RowStyles.Add(new RowStyle(SizeType.Percent,100)); layout.RowStyles.Add(new RowStyle(SizeType.Absolute,46)); Controls.Add(layout);
  layout.Controls.Add(new Label { Text="SWLOR Toolset", Font=new Font("Segoe UI",26,FontStyle.Bold), AutoSize=true });
  layout.Controls.Add(new Label { Text="Download the files, set up the editor and start creating areas.\nNo Visual Studio needed. First-time setup needs internet and may take a while.", Dock=DockStyle.Fill });
  layout.Controls.Add(new Label { Text="Installation folder (files will go into its SWLOR_NWN subfolder)", AutoSize=true });
  var row=new TableLayoutPanel { Dock=DockStyle.Fill, ColumnCount=2 }; row.ColumnStyles.Add(new ColumnStyle(SizeType.Percent,100)); row.ColumnStyles.Add(new ColumnStyle(SizeType.Absolute,100)); folder.Dock=DockStyle.Fill; browse.Text="Browse..."; browse.Dock=DockStyle.Fill; row.Controls.Add(folder); row.Controls.Add(browse); layout.Controls.Add(row);
  Directory.CreateDirectory(state); folder.Text=Path.Combine(Environment.GetEnvironmentVariable("USERPROFILE") ?? Environment.GetFolderPath(Environment.SpecialFolder.UserProfile),"SWLOR");
  try { string pref=Path.Combine(state,"install-parent.txt"); if(File.Exists(pref)) folder.Text=File.ReadAllText(pref); } catch { }
  browse.Click+=delegate { using(var d=new FolderBrowserDialog()) { d.Description="Select the parent folder for SWLOR_NWN"; if(Directory.Exists(folder.Text)) d.SelectedPath=folder.Text; if(d.ShowDialog(this)==DialogResult.OK) folder.Text=d.SelectedPath; } };
  actions.Dock=DockStyle.Fill; layout.Controls.Add(actions);
  AddButton("Install and launch",delegate { Run("Install"); }); AddButton("Launch",delegate { Run("Launch"); }); AddButton("Rebuild and launch",delegate { Run("Rebuild"); });
  actions.SetFlowBreak(actions.Controls[2],true);
  AddButton("Check for updates",delegate { Run("Check"); }); AddButton("Update and launch",delegate { Run("Update"); });
  actions.Controls[0].BackColor=Color.FromArgb(29,70,118); actions.Controls[0].ForeColor=Color.White;
  status.Text="Ready. Internet is needed for first-time setup."; status.Dock=DockStyle.Fill; layout.Controls.Add(status); progress.Dock=DockStyle.Fill; layout.Controls.Add(progress);
  log.Multiline=true; log.ReadOnly=true; log.ScrollBars=ScrollBars.Both; log.WordWrap=false; log.Dock=DockStyle.Fill; log.Font=new Font("Consolas",9); layout.Controls.Add(log);
  utilities.Dock=DockStyle.Fill; utilities.Padding=new Padding(0,6,0,0); layout.Controls.Add(utilities); AddButton("Open files",delegate { OpenFolder(Path.Combine(folder.Text,"SWLOR_NWN")); },utilities); AddButton("Open logs",delegate { OpenFolder(state); },utilities);
  FormClosing+=delegate(object s,FormClosingEventArgs e) { if(busy) { e.Cancel=true; MessageBox.Show(this,"Setup is running. Keep the launcher open until it finishes."); } };
 }
 void AddButton(string title,Action action,FlowLayoutPanel panel=null) { var b=new Button {Text=title,AutoSize=true,MinimumSize=new Size(125,33),Height=33,Padding=new Padding(12,0,12,0)}; b.Click+=delegate {try { action(); } catch(Exception ex) {MessageBox.Show(this,ex.Message,"SWLOR Launcher");}}; (panel??actions).Controls.Add(b); }
 void OpenFolder(string path) { if(!Directory.Exists(path)) throw new IOException("Folder does not exist yet: "+path); Process.Start(new ProcessStartInfo("explorer.exe","\""+path+"\"") {UseShellExecute=true}); }
 void Line(string text) {
  if(text==null || IsDisposed) return;
  BeginInvoke((Action)delegate { log.AppendText(text+Environment.NewLine); if(text.StartsWith("PROGRESS|")) { var a=text.Split('|'); int n; if(a.Length>=3 && int.TryParse(a[1],out n)) {progress.Value=Math.Max(0,Math.Min(100,n));status.Text=a[2];} } });
 }
 void Run(string action) {
  string parent=Path.GetFullPath(folder.Text.Trim());
  if(!Path.IsPathRooted(parent) || parent.StartsWith(@"\\")) throw new IOException("Choose a local absolute folder.");
  File.WriteAllText(Path.Combine(state,"install-parent.txt"),parent);
  string script=Path.Combine(state,"backend-"+Guid.NewGuid().ToString("N")+".ps1");
  using(var s=Assembly.GetExecutingAssembly().GetManifestResourceStream("Backend.ps1")) using(var f=File.Create(script)) s.CopyTo(f);
  // Encoded command keeps quotes, Unicode and PowerShell metacharacters in paths as data.
  string command="& '"+script.Replace("'","''")+"' -Action '"+action+"' -InstallParent '"+parent.Replace("'","''")+"'";
  var info=new ProcessStartInfo(Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.System),@"WindowsPowerShell\v1.0\powershell.exe"),"-NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -EncodedCommand "+Convert.ToBase64String(Encoding.Unicode.GetBytes(command))) {UseShellExecute=false,CreateNoWindow=true,RedirectStandardOutput=true,RedirectStandardError=true};
  var p=new Process { StartInfo=info, EnableRaisingEvents=true };
  p.OutputDataReceived+=delegate(object s,DataReceivedEventArgs e) {Line(e.Data);}; p.ErrorDataReceived+=delegate(object s,DataReceivedEventArgs e) {Line(e.Data);};
  busy=true; actions.Enabled=false; browse.Enabled=false; folder.Enabled=false; log.Clear(); progress.Value=0; status.Text="Starting...";
  System.Threading.ThreadPool.QueueUserWorkItem(delegate {
   int code=-1;
   try { p.Start(); p.BeginOutputReadLine(); p.BeginErrorReadLine(); p.WaitForExit(); code=p.ExitCode; } catch(Exception ex) {Line(ex.Message);} finally {p.Dispose();try {File.Delete(script);}catch{} }
   BeginInvoke((Action)delegate {busy=false;actions.Enabled=true;browse.Enabled=true;folder.Enabled=true;if(code!=0) status.Text="Unable to complete. Read the log above or use Open logs.";else if(action!="Check") status.Text="Toolset launched.";});
  });
 }
}
