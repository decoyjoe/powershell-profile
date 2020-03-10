if (Get-Module -Name 'PSReadLine') {

    # https://github.com/microsoft/terminal/issues/755#issuecomment-546405069
    # if (Test-Path -Path 'Env:\WT_SESSION')
    # {
    #     Set-PSReadLineKeyHandler -Key Ctrl+h -Function BackwardKillWord
    # }

    Set-PSReadlineKeyHandler -Key UpArrow   -Function HistorySearchBackward
    Set-PSReadlineKeyHandler -Key DownArrow -Function HistorySearchForward
    Set-PSReadLineOption -HistorySearchCursorMovesToEnd

    Set-PSReadlineKeyHandler -Key Tab -Function Complete
    Set-PSReadlineKeyHandler -Key "Ctrl+Spacebar" -Function PossibleCompletions
    Set-PSReadlineKeyHandler -Key "Ctrl+Alt+Spacebar" -Function MenuComplete
    Set-PSReadlineKeyHandler -Key "Ctrl+l" -Function ClearScreen
    Set-PSReadlineKeyHandler -Key "Enter" -Function AcceptLine

    Set-PSReadlineKeyHandler -Key "Ctrl+Alt+U" -ScriptBlock {
        Set-Location -Path (Get-Location | Split-Path)
        [Microsoft.PowerShell.PSConsoleReadLine]::AcceptLine()
    }


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

    # F1 for help on the command line - naturally
    Set-PSReadlineKeyHandler -Key F1 `
                             -BriefDescription CommandHelp `
                             -LongDescription "Open the help window for the current command" `
                             -ScriptBlock {
        param($key, $arg)

        $ast = $null
        $tokens = $null
        $errors = $null
        $cursor = $null
        [Microsoft.Powershell.PSConsoleReadLine]::GetBufferState([ref]$ast, [ref]$tokens, [ref]$errors, [ref]$cursor)

        $commandAst = $ast.FindAll( {
            $node = $args[0]
            $node -is [System.Management.Automation.Language.CommandAst] -and
                $node.Extent.StartOffset -le $cursor -and
                $node.Extent.EndOffset -ge $cursor
            }, $true) | Select-Object -Last 1

        if ($commandAst -ne $null)
        {
            $commandName = $commandAst.GetCommandName()
            if ($commandName -ne $null)
            {
                $command = $ExecutionContext.InvokeCommand.GetCommand($commandName, 'All')
                if ($command -is [System.Management.Automation.AliasInfo])
                {
                    $commandName = $command.ResolvedCommandName
                }

                if ($commandName -ne $null)
                {
                    Get-Help $commandName -ShowWindow
                }
            }
        }
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
}