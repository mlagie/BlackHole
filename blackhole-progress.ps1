[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$BlackHolePath,
    [Parameter(Mandatory = $true)][string]$Source
)

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

$form = New-Object Windows.Forms.Form
$form.Text = 'BlackHole'
$form.Width = 640
$form.Height = 190
$form.StartPosition = 'CenterScreen'
$form.FormBorderStyle = 'FixedDialog'
$form.MaximizeBox = $false
$form.MinimizeBox = $false

$label = New-Object Windows.Forms.Label
$label.Text = "Compression de $Source"
$label.AutoSize = $true
$label.Location = New-Object Drawing.Point(18, 15)
$form.Controls.Add($label)

$bar = New-Object Windows.Forms.ProgressBar
$bar.Minimum = 0
$bar.Maximum = 100
$bar.Width = 590
$bar.Location = New-Object Drawing.Point(18, 45)
$form.Controls.Add($bar)

$status = New-Object Windows.Forms.Label
$status.Text = 'Initialisation...' 
$status.AutoSize = $true
$status.Location = New-Object Drawing.Point(18, 78)
$form.Controls.Add($status)

$details = New-Object Windows.Forms.Label
$details.Text = 'Debit : calcul... | Temps restant : calcul...'
$details.AutoSize = $true
$details.Location = New-Object Drawing.Point(18, 105)
$form.Controls.Add($details)

$psi = New-Object Diagnostics.ProcessStartInfo
$psi.FileName = $BlackHolePath
$psi.Arguments = ('compress "{0}" --workers 4' -f $Source)
$psi.UseShellExecute = $false
$psi.CreateNoWindow = $true
$psi.RedirectStandardOutput = $true
$psi.RedirectStandardError = $true
$psi.Environment['BLACKHOLE_PROGRESS'] = 'gui'

$process = New-Object Diagnostics.Process
$process.StartInfo = $psi
$process.EnableRaisingEvents = $true
$process.add_OutputDataReceived({
    param($sender, $event)
    if ($event.Data -match '^(Compression|Ecriture) : (\d+) %(?: - (.*?))? \| Debit : (.*?) \| Temps restant : (.*)$') {
        $phase = $Matches[1]
        $percent = [Math]::Min(100, [int]$Matches[2])
        $file = $Matches[3]
        $speed = $Matches[4]
        $remaining = $Matches[5]
        $form.BeginInvoke([Action]{
            $bar.Value = $percent
            $status.Text = if ($file) { "$phase : $percent % - $file" } else { "$phase : $percent %" }
            $details.Text = "Debit : $speed | Temps restant : $remaining"
        }) | Out-Null
    } elseif ($event.Data -eq "Serialisation de l'archive...") {
        $form.BeginInvoke([Action]{
            $bar.Value = 0
            $status.Text = "Preparation de l'ecriture..."
            $details.Text = 'Debit : calcul... | Temps restant : calcul...'
        }) | Out-Null
    }
})
$process.add_Exited({
    $form.BeginInvoke([Action]{
        if ($process.ExitCode -eq 0) {
            $bar.Value = 100
            $status.Text = 'Compression terminee.'
            $form.DialogResult = [Windows.Forms.DialogResult]::OK
            $form.Close()
        } else {
            [Windows.Forms.MessageBox]::Show($form,
                "Echec de la compression (code $($process.ExitCode)).", 'BlackHole',
                [Windows.Forms.MessageBoxButtons]::OK,
                [Windows.Forms.MessageBoxIcon]::Error) | Out-Null
            $form.DialogResult = [Windows.Forms.DialogResult]::Abort
            $form.Close()
        }
    }) | Out-Null
})
$form.add_FormClosing({
    if (-not $process.HasExited) { $process.Kill() }
})

if (-not $process.Start()) { throw 'Impossible de demarrer BlackHole.' }
$process.BeginOutputReadLine()
$form.ShowDialog() | Out-Null
$process.Dispose()
exit $(if ($form.DialogResult -eq [Windows.Forms.DialogResult]::OK) { 0 } else { 1 })
