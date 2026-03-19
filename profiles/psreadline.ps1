
Set-PSReadLineOption -HistorySearchCursorMovesToEnd
Set-PSReadLineOption -BellStyle None
Set-PSReadLineOption -MaximumHistoryCount 10240

Set-PSReadLineKeyHandler -Key 'Alt+Backspace' -Function BackwardKillWord
Set-PSReadLineKeyHandler -Key 'Alt+LeftArrow' -Function BackwardWord
Set-PSReadLineKeyHandler -Key 'Alt+RightArrow' -Function BackwardWord
Set-PSReadlineKeyHandler -Key UpArrow -Function HistorySearchBackward
Set-PSReadlineKeyHandler -Key DownArrow -Function HistorySearchForward

Set-PSReadlineKeyHandler -Key Tab -Function Complete
Set-PSReadlineKeyHandler -Key "Ctrl+l" -Function ClearScreen
Set-PSReadlineKeyHandler -Key "Enter" -Function AcceptLine

# PowerShell on Windows takes a second or two to exit for some reason ¯\_(ツ)_/¯
# Add some feedback
Set-PSReadLineKeyHandler -Key 'Ctrl+d' -ScriptBlock {
    Write-Host "$([Environment]::NewLine)[exited]"
    [Environment]::Exit(0)
}

# Needed to get Ctrl+v paste working for pwsh in WSL
Set-PSReadLineKeyHandler -Key Ctrl+v -Function Paste

# These "smart" handlers in the rest of the file were pulled from the sample
# profile in the PSReadLine repo:
# https://github.com/PowerShell/PSReadLine/blob/master/PSReadLine/SamplePSReadLineProfile.ps1

# Sometimes you enter a command but realize you forgot to do something else first.
# This binding will let you save that command in the history so you can recall it,
# but it doesn't actually execute.  It also clears the line with RevertLine so the
# undo stack is reset - though redo will still reconstruct the command line.
Set-PSReadlineKeyHandler -Key Alt+s `
                            -BriefDescription SaveInHistory `
                            -LongDescription "Save current line in history but do not execute" `
                            -ScriptBlock {
    param($key, $arg)

    $line = $null
    $cursor = $null
    [Microsoft.Powershell.PSConsoleReadLine]::GetBufferState([ref]$line, [ref]$cursor)
    [Microsoft.Powershell.PSConsoleReadLine]::AddToHistory($line)
    [Microsoft.Powershell.PSConsoleReadLine]::RevertLine()
}

# The next four key handlers are designed to make entering matched quotes
# parens, and braces a nicer experience.  I'd like to include functions
# in the module that do this, but this implementation still isn't as smart
# as ReSharper, so I'm just providing it as a sample.

Set-PSReadlineKeyHandler -Key '"',"'" `
                            -BriefDescription SmartInsertQuote `
                            -LongDescription "Insert paired quotes if not already on a quote" `
                            -ScriptBlock {
    param($key, $arg)

    $line = $null
    $cursor = $null
    [Microsoft.Powershell.PSConsoleReadLine]::GetBufferState([ref]$line, [ref]$cursor)

    $cursorCharacter = $null
    if ($cursor -ne $line.length)
    {
        $cursorCharacter = $line[$cursor]
    }

    if ($cursorCharacter -eq $key.KeyChar) {
        # Just move the cursor
        [Microsoft.Powershell.PSConsoleReadLine]::SetCursorPosition($cursor + 1)
    }
    elseif ( ($line.length -eq 0) -OR ($line[$cursor - 1] -eq " " -and ($cursorCharacter -eq " " -OR $cursorCharacter -eq $null)) ) {
        # Insert matching quotes, move cursor to be in between the quotes
        [Microsoft.Powershell.PSConsoleReadLine]::Insert("$($key.KeyChar)" * 2)
        [Microsoft.Powershell.PSConsoleReadLine]::GetBufferState([ref]$line, [ref]$cursor)
        [Microsoft.Powershell.PSConsoleReadLine]::SetCursorPosition($cursor - 1)
    }
    else {
        [Microsoft.Powershell.PSConsoleReadLine]::Insert("$($key.KeyChar)")
    }
}

Set-PSReadlineKeyHandler -Key '(','{','[' `
                            -BriefDescription InsertPairedBraces `
                            -LongDescription "Insert matching braces" `
                            -ScriptBlock {
    param($key, $arg)

    $line = $null
    $cursor = $null
    [Microsoft.Powershell.PSConsoleReadLine]::GetBufferState([ref]$line, [ref]$cursor)

    $closeChar = switch ($key.KeyChar)
    {
        <#case#> '(' { [char]')'; break }
        <#case#> '{' { [char]'}'; break }
        <#case#> '[' { [char]']'; break }
    }

    $cursorCharacter = $null
    if ($cursor -ne $line.length)
    {
        $cursorCharacter = $line[$cursor]
    }

    if (($cursorCharacter -eq $null) -OR ($cursorCharacter -eq " ") -OR ($cursorCharacter -eq $closeChar)) {
        [Microsoft.Powershell.PSConsoleReadLine]::Insert("$($key.KeyChar)$closeChar")
        $line = $null
        $cursor = $null
        [Microsoft.Powershell.PSConsoleReadLine]::GetBufferState([ref]$line, [ref]$cursor)
        [Microsoft.Powershell.PSConsoleReadLine]::SetCursorPosition($cursor - 1)
    }
    else {
        [Microsoft.Powershell.PSConsoleReadLine]::Insert("$($key.KeyChar)")
    }

}

Set-PSReadlineKeyHandler -Key ')',']','}' `
                            -BriefDescription SmartCloseBraces `
                            -LongDescription "Insert closing brace or skip" `
                            -ScriptBlock {
    param($key, $arg)

    $line = $null
    $cursor = $null
    [Microsoft.Powershell.PSConsoleReadLine]::GetBufferState([ref]$line, [ref]$cursor)

    $cursorCharacter = $null
    if ($cursor -ne $line.length)
    {
        $cursorCharacter = $line[$cursor]
    }

    if ($cursorCharacter -eq $key.KeyChar)
    {
        [Microsoft.Powershell.PSConsoleReadLine]::SetCursorPosition($cursor + 1)
    }
    else
    {
        [Microsoft.Powershell.PSConsoleReadLine]::Insert("$($key.KeyChar)")
    }
}

Set-PSReadlineKeyHandler -Key Backspace `
                            -BriefDescription SmartBackspace `
                            -LongDescription "Delete previous character or matching quotes/parens/braces" `
                            -ScriptBlock {
    param($key, $arg)

    $line = $null
    $cursor = $null
    [Microsoft.Powershell.PSConsoleReadLine]::GetBufferState([ref]$line, [ref]$cursor)

    if ($cursor -gt 0)
    {
        $cursorCharacter = $null
        if ($cursor -ne $line.length)
        {
            $cursorCharacter = $line[$cursor]
        }

        $toMatch = $null
        switch ($cursorCharacter)
        {
            <#case#> '"' { $toMatch = '"'; break }
            <#case#> "'" { $toMatch = "'"; break }
            <#case#> ')' { $toMatch = '('; break }
            <#case#> ']' { $toMatch = '['; break }
            <#case#> '}' { $toMatch = '{'; break }
        }

        if ($toMatch -ne $null -and $line[$cursor-1] -eq $toMatch)
        {
            [Microsoft.Powershell.PSConsoleReadLine]::Delete($cursor - 1, 2)
        }
        else
        {
            [Microsoft.Powershell.PSConsoleReadLine]::BackwardDeleteChar($key, $arg)
        }
    }
    else
    {
        [Microsoft.Powershell.PSConsoleReadLine]::BackwardDeleteChar($key, $arg)
    }
}
