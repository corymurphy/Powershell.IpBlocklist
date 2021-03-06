$configJson = '
    {
        "SmtpServer" : "smtp.gmail.com",
        "GmailUser" : "",
        "GmailPassword" : "",
        "SendEmailTo" : "",
        "Whitelist" : [ "192.168.1.*" ],
        "FailedLoginThresholdCount" : 5,
        "FailedLoginThresholdInterval" : 60,
        "FirewallRuleName" : "IpBlocklist",
        "Debug" : "true",
        "DebugFileName" : "debug.log",
        "ReadOnly" : "false"
    }
';

function Get-IpWhitelist
{
    param
    (
        [object]$Config
    )

    $whitelist = (New-Object -TypeName 'System.Collections.Generic.List[string]' -ArgumentList 0);

    foreach($ip in $Config.Whitelist)
    {
        $parsed = $false;

        if([string]::IsNullOrWhiteSpace($ip))
        {
            continue;
        }

        try
        {
            [ipaddress]$ip | Out-Null;
            $parsed = $true;
            $whitelist.Add($ip);
        }
        catch
        {

        }


        if($parsed)
        {
            continue;
        }
        

        try
        {
            [ipaddress]($ip.Replace('*', 0)) | Out-Null;

            foreach($octet in (1..254) )
            {
                $new = $ip.Replace('*', $octet);
                [ipaddress]$new| Out-Null;
                $whitelist.Add($new);
            }
        }
        catch
        {
            continue;
        }
    }
    return $whitelist;
}

function Get-NotificationEmailBody
{
    param
    (
        [System.Collections.Generic.List[string]]$IpBlocklist
    )

    $sb = New-Object -TypeName 'System.Text.StringBuilder' -ArgumentList 'The following IPs were added to the firewall blocklist';

    $sb.AppendLine('') | Out-Null;
    $sb.AppendLine('') | Out-Null;

    foreach($ip in $IpBlocklist)
    {
        $sb.AppendLine($ip) | Out-Null;
    }
    
    return $sb.ToString();
}

function Get-CurrentBlocklist
{
    param
    (
        [string]$FirewallRuleName
    )
    try
    {
        $rule = Get-NetFirewallRule -DisplayName:$FirewallRuleName -ErrorAction:'Stop';
        return ($rule | Get-NetFirewallAddressFilter).RemoteAddress;
    }
    catch
    {
        return ,(New-Object -TypeName 'System.Collections.Generic.List[string]' -ArgumentList 0) ;
    }
}

function Test-IpBlocklistFirewallRuleExists
{
    param
    (
        [string]$FirewallRuleName
    )

    try
    {
        Get-NetFirewallRule -DisplayName:$FirewallRuleName -ErrorAction:'Stop' | Out-Null;
        $ruleExists = $true;
    }
    catch
    {
        $ruleExists = $false;
    }

    return $ruleExists
}

function Set-RdpBlocklistFirewallRule
{
    param
    (
        [System.Collections.Generic.List[string]]$IpBlocklist,
        [string]$FirewallRuleName
    )

    $ruleExists = Test-IpBlocklistFirewallRuleExists -FirewallRuleName:$FirewallRuleName;
    $ruleUpdated = $false;

    $ruleScope = Get-CurrentBlocklist -FirewallRuleName:$FirewallRuleName;
    #$ruleScope = ($rule | Get-NetFirewallAddressFilter).RemoteAddress;

    if($ruleExists)
    {
        if($ruleScope -eq 'Any')
        {
            Get-NetFirewallRule -DisplayName:$FirewallRuleName | Set-NetFirewallRule -RemoteAddress:$IpBlocklist | Out-Null;
        }
        else
        {

            foreach($ip in $IpBlocklist)
            {
                if( -not $ruleScope.Contains($ip) )
                {
                    $ruleUpdated = $true;
                }
            }

            #Ensure that IPs that are already blocked, are not removed when the new set of IPs is defined. 
            foreach($existingIp in $ruleScope)
            {
                if( -not ($IpBlocklist.Contains($existingIp)) )
                {
                    $ruleUpdated = $true;
                    $IpBlocklist.Add($existingIp);
                }
            }            

            if($ruleUpdated)
            {
                Get-NetFirewallRule -DisplayName:$FirewallRuleName | Set-NetFirewallRule -RemoteAddress:$IpBlocklist | Out-Null;
            }
        }
    }
    else
    {
        $ruleUpdated = $true;
        New-NetFirewallRule -PolicyStore:'PersistentStore' -DisplayName:'IpBlocklist' -RemoteAddress:$IpBlocklist -Action Block | Out-Null;
    }

    return $ruleUpdated;
}

function Get-RrasPreSharedKeyAuthenticationFailures
{
    #4653

    $filter = @{
        LogName = 'Security';
        ID = '4653';
    }
    $selectedProperties = @(
        'TimeCreated',
        @{Name="IpAddress";Expression={ ([xml]($_.ToXml())).SelectSingleNode("//*[@Name='RemoteAddress']").'#text' }}
    )
    $events = Get-WinEvent -FilterHashtable $filter | Select-Object -Property $selectedProperties;

    return $events;
}

function Get-RrasAuthenticationFailures
{
    
}

function Get-AuthenticationFailureEvents
{
    param
    (
        [object]$Config,
        [string]$EventLogFilePath
    )


    $selectedProperties = @(
        'TimeCreated',
        @{Name="IpAddress";Expression={ ([xml]($_.ToXml())).SelectSingleNode("//*[@Name='IpAddress']").'#text' }},
        @{Name="Status";Expression={ ([xml]($_.ToXml())).SelectSingleNode("//*[@Name='Status']").'#text' }}
    );

    # 0xC000006D |  This is either due to a bad username or authentication information

    if([string]::IsNullOrWhiteSpace($EventLogFilePath))
    {
        $filter = @{
            LogName = 'Security';
            ID = '4625';
        }

        $secEvents = Get-WinEvent -FilterHashtable $filter | Select-Object -Property $selectedProperties | Where-Object -FilterScript {$_.Status -eq '0xC000006D'}
    }
    else
    {
        #$xpath = '*[System[(EventID=4625) and TimeCreated[timediff(@SystemTime) <= 172800000]]]'
        $xpath = "*[System[(EventID=4625)]]";
        $secEvents = Get-WinEvent -Path $EventLogFilePath -FilterXPath $xpath | Select-Object -Property $selectedProperties | Where-Object -FilterScript {$_.Status -eq '0xC000006D'}
    }

    $rrasEvents = Get-RrasPreSharedKeyAuthenticationFailures;

    $events = New-Object -TypeName 'System.Collections.Generic.List[object]';

    $events.AddRange($rrasEvents);
    $events.AddRange($secEvents);

    return $events;
}

function Convert-GenericListToString
{
    param
    (
        [System.Collections.Generic.List[string]]$List
    )

    $sb = New-Object -TypeName 'System.Text.StringBuilder' -ArgumentList ('Found {0} potentially malicous IPs durring this run.' -f $List.Count);

    $sb.AppendLine('') | Out-Null;

    foreach($item in $List)
    {
        $sb.AppendLine($item) | Out-Null;
    }

    $sb.AppendLine('') | Out-Null;
    
    return $sb.ToString();
}


#$events[50]

function Invoke-RdpIpRestrictionJob
{
    param
    (
        [object]$Config,
        [string]$EventLogFilePath
    )

    if([bool]($Config.Debug))
    {
        Out-File -FilePath $Config.DebugFileName -InputObject ('IP Blocklist job started at {0}' -f [datetime]::Now) -Append;
    }

    $start = [datetime]::Now;

    $ipBlocklist = New-Object -TypeName 'System.Collections.Generic.List[string]'
    
    $events = Get-AuthenticationFailureEvents -Config:$Config -EventLogFilePath:$EventLogFilePath

    $currentBlocklist = Get-CurrentBlocklist -FirewallRuleName:$Config.FirewallRuleName;

    $BlocklistUpdated = $false;

    $whitelist = Get-IpWhitelist -Config:$Config;

    $lastEventTime = [datetime]::MinValue;

    $skipMinutes = (([int]($config.FailedLoginThresholdInterval)) / 2);

    $firstEvent = $true;

    $readonly = ([bool]::Parse($Config.ReadOnly));

    foreach($authEvent in $events)
    {
        if($firstEvent)
        {
            $lastEventTime = $authEvent.TimeCreated;
            $firstEvent = $false;
        }

        #Skip ahead to improve search performance - Events will be skipped if the last processed event is within half of the FailedLoginThresholdInterval
        if( -not ( ($authEvent.TimeCreated -lt $lastEventTime.AddMinutes($skipMinutes)) -and ($authEvent.TimeCreated -gt $lastEventTime.AddMinutes( ('-' + $skipMinutes) ) ) ) )
        {
            $lastEventTime = $authEvent.TimeCreated;

            $timeMin = $authEvent.TimeCreated.AddMinutes( ('-' + $Config.FailedLoginThresholdInterval) );
            $timeMax = $authEvent.TimeCreated.AddMinutes( $Config.FailedLoginThresholdInterval );

            $eventsWithinThreshhold = $events | Where-Object -FilterScript { $_.TimeCreated -gt $timeMin -and $_.TimeCreated -lt $timeMax}

            $uniqueIpWithinThreshhold = ($eventsWithinThreshhold.IpAddress | Select-Object -Unique);

            foreach($ip in $uniqueIpWithinThreshhold)
            {
                $iPsWithinThreshold = ($eventsWithinThreshhold.IpAddress | Where-Object -FilterScript {$_ -eq $ip}).Count;
                if($iPsWithinThreshold -ge $Config.FailedLoginThresholdCount)
                {
                    if( (-not $ipBlocklist.Contains($ip)) -and (-not $whitelist.Contains($ip)) -and (-not $currentBlocklist.Contains($ip) ) )
                    {
                        try
                        {
                            $BlocklistUpdated = $true;
                            [ipaddress]$ip | Out-Null;
                            $ipBlocklist.Add($ip);
                        }
                        catch
                        {
                            # Do nothing, this means there is an invalid IP
                        }
                    }
                }
            }
        }

    }

    if([bool]($Config.Debug))
    {
        Out-File -FilePath $Config.DebugFileName -InputObject (Convert-GenericListToString -List:$ipBlocklist) -Append;
    }

    if( -not ($ipBlocklist -eq $null -or $ipBlocklist.Count -lt 1) )
    {
        
        if ( $readonly -eq $false)
        {
            $ruleUpdated = Set-RdpBlocklistFirewallRule -IpBlocklist:$ipBlocklist -FirewallRuleName:$Config.FirewallRuleName;
        }
        
        if($ruleUpdated)
        {
            $pwd = $Config.GmailPassword | ConvertTo-SecureString -Force -AsPlainText;
            $cred = New-Object 'System.Management.Automation.PSCredential' -ArgumentList @($Config.GmailUser, $pwd);

            $mailArgs = @{
                SmtpServer = $Config.SmtpServer;
                Body = (Get-NotificationEmailBody -IpBlocklist:$ipBlocklist);
                From = $Config.GmailUser;
                To = $Config.SendEmailTo;
                Port = 587;
                Subject = 'Firewall IP Blocklist Rule was Updated';
                Credential = $cred;
                UseSsl = $true;
            }
            Send-MailMessage @mailArgs;
        }
        
    }

    $finish = [datetime]::Now;

    $runtime = [System.Math]::Round(($finish - $start).TotalSeconds)

    if([bool]($Config.Debug))
    {
        Out-File -FilePath $Config.DebugFileName -InputObject ('IP Blocklist job finished at {0} and took {1} second(s)' -f $finish,$runtime) -Append;
    }
}

Invoke-RdpIpRestrictionJob -Config:($configJson | ConvertFrom-Json) 
#-EventLogFilePath:"C:\Users\cmurphya\Desktop\all.evtx";
