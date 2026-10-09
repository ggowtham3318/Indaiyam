$ErrorActionPreference = "Stop"

$baseUrl = $env:SUPABASE_URL
$anonKey = $env:SUPABASE_ANON_KEY
$serviceKey = $env:SUPABASE_SERVICE_ROLE_KEY
if ([string]::IsNullOrWhiteSpace($baseUrl) -or [string]::IsNullOrWhiteSpace($anonKey) -or [string]::IsNullOrWhiteSpace($serviceKey)) {
  throw "Set SUPABASE_URL, SUPABASE_ANON_KEY, and SUPABASE_SERVICE_ROLE_KEY."
}

$run = [guid]::NewGuid().ToString("N")
$users = @{}
$failures = 0

function Call-Api($method, $path, $token, $body, $schema = "app") {
  $headers = @{ apikey = $anonKey; Authorization = "Bearer $token" }
  if ($schema) {
    $headers["Accept-Profile"] = $schema
    $headers["Content-Profile"] = $schema
  }
  if ($body) { $headers["Content-Type"] = "application/json" }
  try {
    $params = @{ Method = $method; Uri = "$baseUrl$path"; Headers = $headers; ErrorAction = "Stop"; UseBasicParsing = $true }
    if ($body) { $params.Body = ($body | ConvertTo-Json -Depth 10) }
    $response = Invoke-WebRequest @params
    return [pscustomobject]@{ Status = [int]$response.StatusCode; Data = $(if ($response.Content) { $response.Content | ConvertFrom-Json } else { $null }) }
  } catch {
    $status = 0
    if ($_.Exception.Response) { $status = [int]$_.Exception.Response.StatusCode }
    $errorData = $null
    if ($_.Exception.Response) {
      $reader = New-Object System.IO.StreamReader($_.Exception.Response.GetResponseStream())
      $errorContent = $reader.ReadToEnd()
      if ($errorContent) { $errorData = $errorContent | ConvertFrom-Json }
    }
    return [pscustomobject]@{ Status = $status; Data = $errorData; Error = $_.Exception.Message }
  }
}

function Check($name, $condition) {
  if ($condition) { Write-Output "PASS $name" }
  else { Write-Output "FAIL $name"; $script:failures++ }
}

function Create-AdminUser($email, $password) {
  $headers = @{ apikey = $anonKey; Authorization = "Bearer $serviceKey"; "Content-Type" = "application/json" }
  $body = @{ email = $email; password = $password; email_confirm = $true } | ConvertTo-Json
  return Invoke-RestMethod -Method Post -Uri "$baseUrl/auth/v1/admin/users" -Headers $headers -Body $body
}

function Login($email, $password) {
  $headers = @{ apikey = $anonKey; "Content-Type" = "application/json" }
  $body = @{ email = $email; password = $password } | ConvertTo-Json
  return (Invoke-RestMethod -Method Post -Uri "$baseUrl/auth/v1/token?grant_type=password" -Headers $headers -Body $body).access_token
}

function Delete-User($id) {
  $headers = @{ apikey = $anonKey; Authorization = "Bearer $serviceKey" }
  Invoke-RestMethod -Method Delete -Uri "$baseUrl/auth/v1/admin/users/$id" -Headers $headers | Out-Null
}

function Storage-Call($method, $path, $token, $file, $contentType) {
  $headers = @{ apikey = $anonKey; Authorization = "Bearer $token"; "Content-Type" = $contentType }
  try {
    $params = @{ Method = $method; Uri = "$baseUrl/storage/v1/object/$path"; Headers = $headers; ErrorAction = "Stop"; UseBasicParsing = $true }
    if ($file) { $params.InFile = $file }
    $response = Invoke-WebRequest @params
    return [int]$response.StatusCode
  } catch {
    if ($_.Exception.Response) { return [int]$_.Exception.Response.StatusCode }
    return 0
  }
}

$password = "RlsTest@12345"
try {
  foreach ($name in @("userA", "userB", "userC", "staff", "admin")) {
    $email = "rls-test-$name-$run@example.com"
    $user = Create-AdminUser $email $password
    $userId = $user.id
    if (-not $userId -and $user.user) { $userId = $user.user.id }
    $users[$name] = [pscustomobject]@{ Id = $userId; Email = $email; Token = (Login $email $password) }
  }

  $staffHeaders = @{ apikey = $anonKey; Authorization = "Bearer $serviceKey"; "Content-Type" = "application/json"; "Content-Profile" = "app"; "Accept-Profile" = "app" }
  foreach ($role in @(@("staff", "moderator"), @("admin", "admin"))) {
    $row = @{ user_id = $users[$role[0]].Id; role = $role[1] } | ConvertTo-Json
    Invoke-RestMethod -Method Post -Uri "$baseUrl/rest/v1/user_roles" -Headers $staffHeaders -Body $row | Out-Null
  }

  foreach ($name in @("userA", "userB", "userC")) {
    $contact = @{ user_id = $users[$name].Id; phone = "+91987654$((Get-Random -Minimum 1000 -Maximum 9999))"; email = $users[$name].Email; whatsapp = "+91987654$((Get-Random -Minimum 1000 -Maximum 9999))" }
    $response = Call-Api "POST" "/rest/v1/user_contact_details" $serviceKey $contact
    Check "contact fixture $name" ($response.Status -eq 201 -or $response.Status -eq 200)
  }

  $profiles = @{}
  foreach ($name in @("userA", "userB", "userC")) {
    $response = Call-Api "GET" "/rest/v1/profiles?user_id=eq.$($users[$name].Id)&select=id,status" $serviceKey $null
    $profile = @($response.Data)[0]
    $profiles[$name] = $profile.id
    Check "signup creates draft profile $name" ($response.Status -eq 200 -and $profile.status -eq "draft")
  }
  $searchDraft = Call-Api "POST" "/rest/v1/rpc/public_teaser_profiles" $null @{} ""
  Check "draft profiles excluded from public teaser" (-not ($searchDraft.Data | Where-Object { $_.display_name -like "rls-test*" }))

  $adminApprove = @{ p_profile_id = $profiles["userA"]; p_status = "approved"; p_reason = $null }
  $normalApprove = Call-Api "POST" "/rest/v1/rpc/admin_set_profile_status" $users["userA"].Token $adminApprove
  Check "normal user cannot approve profile" ($normalApprove.Status -ge 400)
  $selfPatch = Call-Api "PATCH" "/rest/v1/profiles?id=eq.$($profiles["userC"])" $users["userC"].Token @{ status = "approved" }
  Check "owner cannot self-approve" ($selfPatch.Status -ge 400)
  $staffApprove = Call-Api "POST" "/rest/v1/rpc/admin_set_profile_status" $users["admin"].Token $adminApprove
  Check "admin can approve profile" ($staffApprove.Status -eq 200)
  foreach ($name in @("userA", "userB", "userC")) {
    $approve = @{ p_profile_id = $profiles[$name]; p_status = "approved"; p_reason = $null }
    Check "admin approves $name" ((Call-Api "POST" "/rest/v1/rpc/admin_set_profile_status" $users["admin"].Token $approve).Status -eq 200)
  }
  $searchBody = @{
    p_limit = 100; p_offset = 0
  }
  $approvedSearch = Call-Api "POST" "/rest/v1/rpc/search_profiles" $users["userA"].Token $searchBody
  $approvedIds = @($approvedSearch.Data) | ForEach-Object { $_.id }
  if ($approvedIds -notcontains $profiles["userC"]) { Write-Output "INFO search status=$($approvedSearch.Status) error=$($approvedSearch.Error)" }
  Check "approved profile appears in search" ($approvedIds -contains $profiles["userC"])
  Check "approved profile detail is visible" ((Call-Api "POST" "/rest/v1/rpc/get_profile_detail" $users["userA"].Token @{ p_profile_id = $profiles["userC"] }).Status -eq 200)
  foreach ($state in @("suspended", "rejected", "deleted")) {
    $change = @{ p_profile_id = $profiles["userC"]; p_status = $state; p_reason = "rls test" }
    Check "admin sets profile $state" ((Call-Api "POST" "/rest/v1/rpc/admin_set_profile_status" $users["admin"].Token $change).Status -eq 200)
    $hidden = Call-Api "POST" "/rest/v1/rpc/get_profile_detail" $users["userA"].Token @{ p_profile_id = $profiles["userC"] }
    Check "$state profile hidden from detail" ($null -eq $hidden.Data.id)
  }

  $interest = Call-Api "POST" "/rest/v1/rpc/send_interest" $users["userA"].Token @{ p_receiver_user_id = $users["userB"].Id; p_message = "hello" }
  Check "send interest" ($interest.Status -eq 200)
  $duplicate = Call-Api "POST" "/rest/v1/rpc/send_interest" $users["userA"].Token @{ p_receiver_user_id = $users["userB"].Id }
  Check "duplicate interest blocked" ($duplicate.Status -ge 400)
  $spoof = Call-Api "POST" "/rest/v1/interests" $users["userA"].Token @{ sender_user_id = $users["userB"].Id; receiver_user_id = $users["userC"].Id }
  Check "interest sender spoof blocked" ($spoof.Status -ge 400)

  $beforeContact = Call-Api "POST" "/rest/v1/rpc/get_contact_details" $users["userA"].Token @{ p_target_user_id = $users["userB"].Id }
  Check "contact hidden before acceptance" ($beforeContact.Status -ge 400)
  $interestId = $interest.Data.id
  $senderAccept = Call-Api "POST" "/rest/v1/rpc/respond_interest" $users["userA"].Token @{ p_interest_id = $interestId; p_status = "accepted" }
  Check "sender cannot accept" ($senderAccept.Status -ge 400)
  $receiverAccept = Call-Api "POST" "/rest/v1/rpc/respond_interest" $users["userB"].Token @{ p_interest_id = $interestId; p_status = "accepted" }
  Check "receiver can accept" ($receiverAccept.Status -eq 200)
  Check "contact visible after acceptance" ((Call-Api "POST" "/rest/v1/rpc/get_contact_details" $users["userA"].Token @{ p_target_user_id = $users["userB"].Id }).Status -eq 200)
  Check "unrelated user cannot see contact" ((Call-Api "POST" "/rest/v1/rpc/get_contact_details" $users["userC"].Token @{ p_target_user_id = $users["userB"].Id }).Status -ge 400)
  $withdraw = Call-Api "POST" "/rest/v1/rpc/withdraw_interest" $users["userA"].Token @{ p_interest_id = $interestId }
  Check "sender can withdraw" ($withdraw.Status -eq 200)
  Check "contact hidden after withdrawal" ((Call-Api "POST" "/rest/v1/rpc/get_contact_details" $users["userA"].Token @{ p_target_user_id = $users["userB"].Id }).Status -ge 400)

  $small = Join-Path $env:TEMP "rls-photo-$run.jpg"
  $text = Join-Path $env:TEMP "rls-file-$run.txt"
  $large = Join-Path $env:TEMP "rls-large-$run.jpg"
  [IO.File]::WriteAllBytes($small, [byte[]](0xFF, 0xD8, 0xFF, 0xD9))
  [IO.File]::WriteAllText($text, "not an image")
  [IO.File]::WriteAllBytes($large, (New-Object byte[] 5242881))
  Check "own pending photo upload" ((Storage-Call "POST" "photos-pending/$($users["userA"].Id)/photo.jpg" $users["userA"].Token $small "image/jpeg") -eq 200)
  Check "other user's pending folder rejected" ((Storage-Call "POST" "photos-pending/$($users["userB"].Id)/photo.jpg" $users["userA"].Token $small "image/jpeg") -ge 400)
  Check "wrong photo MIME rejected" ((Storage-Call "POST" "photos-pending/$($users["userA"].Id)/file.txt" $users["userA"].Token $text "text/plain") -ge 400)
  Check "oversized photo rejected" ((Storage-Call "POST" "photos-pending/$($users["userA"].Id)/large.jpg" $users["userA"].Token $large "image/jpeg") -ge 400)
  Check "non-staff approved upload rejected" ((Storage-Call "POST" "photos-approved/$($users["userA"].Id)/photo.jpg" $users["userA"].Token $small "image/jpeg") -ge 400)
  Check "cross-user horoscope read rejected" ((Storage-Call "GET" "horoscopes-private/$($users["userA"].Id)/missing.jpg" $users["userB"].Token $null "image/jpeg") -ge 400)
  Remove-Item -LiteralPath $small, $text, $large -Force
}
finally {
  foreach ($name in $users.Keys) {
    try { Delete-User $users[$name].Id } catch {}
  }
}

if ($failures -gt 0) { exit 1 }
Write-Output "ALL TESTS PASSED"
