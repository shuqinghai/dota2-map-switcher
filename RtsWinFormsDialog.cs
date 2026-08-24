using System;
using System.Drawing;
using System.Windows.Forms;

internal static class RtsMessageBox
{
    public static DialogResult Show(
        string message,
        string title,
        MessageBoxButtons buttons,
        MessageBoxIcon icon)
    {
        return Show(null, message, title, buttons, icon);
    }

    public static DialogResult Show(
        IWin32Window owner,
        string message,
        string title,
        MessageBoxButtons buttons,
        MessageBoxIcon icon)
    {
        using (Form dialog = new Form())
        using (Label titleLabel = new Label())
        using (Label messageLabel = new Label())
        using (Button primaryButton = CreateButton("确定", true))
        {
            Color accent = GetAccent(icon);
            dialog.Text = title ?? String.Empty;
            dialog.FormBorderStyle = FormBorderStyle.FixedDialog;
            dialog.StartPosition = owner == null ? FormStartPosition.CenterScreen : FormStartPosition.CenterParent;
            dialog.MaximizeBox = false;
            dialog.MinimizeBox = false;
            dialog.ShowIcon = false;
            dialog.ShowInTaskbar = false;
            dialog.BackColor = Color.FromArgb(8, 16, 22);
            dialog.ForeColor = Color.FromArgb(228, 215, 180);
            dialog.Font = new Font("Microsoft YaHei UI", 9F, FontStyle.Regular, GraphicsUnit.Point);
            dialog.ClientSize = new Size(560, 220);
            dialog.Padding = new Padding(18);

            titleLabel.AutoSize = false;
            titleLabel.Location = new Point(28, 24);
            titleLabel.Size = new Size(504, 30);
            titleLabel.Text = title ?? String.Empty;
            titleLabel.ForeColor = Color.FromArgb(214, 168, 59);
            titleLabel.Font = new Font(dialog.Font.FontFamily, 13F, FontStyle.Bold);

            messageLabel.AutoSize = true;
            messageLabel.MaximumSize = new Size(500, 0);
            messageLabel.Location = new Point(28, 68);
            messageLabel.Text = message ?? String.Empty;
            messageLabel.ForeColor = Color.FromArgb(221, 213, 196);
            messageLabel.Font = new Font(dialog.Font.FontFamily, 9.5F, FontStyle.Regular);

            dialog.Controls.Add(titleLabel);
            dialog.Controls.Add(messageLabel);
            dialog.CreateControl();
            int contentBottom = messageLabel.Bottom;
            int buttonTop = Math.Max(146, contentBottom + 24);
            dialog.ClientSize = new Size(560, buttonTop + 58);

            primaryButton.DialogResult = DialogResult.OK;
            primaryButton.Location = new Point(424, buttonTop);
            dialog.Controls.Add(primaryButton);
            dialog.AcceptButton = primaryButton;

            if (buttons == MessageBoxButtons.OKCancel)
            {
                using (Button secondaryButton = CreateButton("取消", false))
                {
                    secondaryButton.DialogResult = DialogResult.Cancel;
                    secondaryButton.Location = new Point(310, buttonTop);
                    dialog.Controls.Add(secondaryButton);
                    dialog.CancelButton = secondaryButton;
                    dialog.Paint += delegate(object sender, PaintEventArgs e) { DrawFrame(e.Graphics, dialog.ClientRectangle, accent); };
                    return owner == null ? dialog.ShowDialog() : dialog.ShowDialog(owner);
                }
            }

            dialog.CancelButton = primaryButton;
            dialog.Paint += delegate(object sender, PaintEventArgs e) { DrawFrame(e.Graphics, dialog.ClientRectangle, accent); };
            return owner == null ? dialog.ShowDialog() : dialog.ShowDialog(owner);
        }
    }

    private static Button CreateButton(string text, bool primary)
    {
        Button button = new Button();
        button.Text = text;
        button.Size = new Size(108, 36);
        button.FlatStyle = FlatStyle.Flat;
        button.FlatAppearance.BorderSize = 1;
        button.FlatAppearance.BorderColor = Color.FromArgb(146, 113, 47);
        button.FlatAppearance.MouseOverBackColor = primary
            ? Color.FromArgb(24, 92, 171)
            : Color.FromArgb(25, 57, 77);
        button.FlatAppearance.MouseDownBackColor = Color.FromArgb(8, 43, 96);
        button.BackColor = primary
            ? Color.FromArgb(12, 61, 133)
            : Color.FromArgb(17, 30, 37);
        button.ForeColor = Color.FromArgb(240, 201, 87);
        button.Font = new Font("Microsoft YaHei UI", 9F, FontStyle.Bold, GraphicsUnit.Point);
        button.Cursor = Cursors.Hand;
        return button;
    }

    private static Color GetAccent(MessageBoxIcon icon)
    {
        if (icon == MessageBoxIcon.Error) { return Color.FromArgb(113, 58, 50); }
        if (icon == MessageBoxIcon.Warning) { return Color.FromArgb(140, 105, 42); }
        if (icon == MessageBoxIcon.Information) { return Color.FromArgb(73, 107, 57); }
        return Color.FromArgb(65, 92, 114);
    }

    private static void DrawFrame(Graphics graphics, Rectangle bounds, Color accent)
    {
        using (Pen outer = new Pen(Color.FromArgb(70, 82, 84), 3F))
        using (Pen inner = new Pen(Color.FromArgb(146, 113, 47), 1F))
        using (Pen separator = new Pen(accent, 1F))
        {
            graphics.DrawRectangle(outer, 2, 2, bounds.Width - 5, bounds.Height - 5);
            graphics.DrawRectangle(inner, 6, 6, bounds.Width - 13, bounds.Height - 13);
            graphics.DrawLine(separator, 28, 58, bounds.Width - 28, 58);
        }
    }
}
