// Kleiner Starter fuer CamOffload: startet CamOffload.ps1 (liegt im selben Ordner) ohne Konsolenfenster.
using System;
using System.Diagnostics;
using System.IO;
using System.Windows.Forms;

[assembly: System.Reflection.AssemblyTitle("CamOffload")]
[assembly: System.Reflection.AssemblyProduct("CamOffload")]
[assembly: System.Reflection.AssemblyVersion("1.0.0.0")]

static class Launcher
{
    [STAThread]
    static void Main()
    {
        string dir = AppDomain.CurrentDomain.BaseDirectory;
        string ps1 = Path.Combine(dir, "CamOffload.ps1");
        if (!File.Exists(ps1))
        {
            MessageBox.Show("CamOffload.ps1 wurde nicht gefunden in:\n" + dir, "CamOffload", MessageBoxButtons.OK, MessageBoxIcon.Error);
            return;
        }
        var psi = new ProcessStartInfo(
            Environment.ExpandEnvironmentVariables(@"%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe"),
            "-NoProfile -STA -ExecutionPolicy Bypass -WindowStyle Hidden -File \"" + ps1 + "\"");
        psi.UseShellExecute = false;
        psi.CreateNoWindow = true;
        psi.WorkingDirectory = dir;
        Process.Start(psi);
    }
}
