param (
  [Parameter(Mandatory = $true)]
  [ValidateSet('amazon', 'azure', 'google')]
  [string] $platform,

  [Parameter(Mandatory = $true)]
  [ValidateSet('win10-64', 'win10-64-gpu', 'win7-32', 'win7-32-gpu', 'win2012', 'win2019')]
  [string] $imageKey,
  [string] $group,
  [switch] $enableSnapshotCopy = $false
)

# job settings. change these for the tasks at hand.
#$VerbosePreference = 'continue';
$workFolder = (Resolve-Path -Path ('{0}\..' -f $PSScriptRoot));

# constants and script config. these are probably ok as they are.
$revision = $(& git rev-parse HEAD);
if (@(Get-PSRepository -Name 'PSGallery')[0].InstallationPolicy -ne 'Trusted') {
  Set-PSRepository -Name 'PSGallery' -InstallationPolicy 'Trusted';
}
foreach ($rm in @(
  @{ 'module' = 'posh-minions-managed'; 'version' = '0.0.72' },
  @{ 'module' = 'powershell-yaml'; 'version' = '0.4.1' }
)) {
  $module = (Get-Module -Name $rm.module -ErrorAction SilentlyContinue);
  if ($module) {
    if ($module.Version -lt $rm.version) {
      Update-Module -Name $rm.module -RequiredVersion $rm.version;
    }
  } else {
    Install-Module -Name $rm.module -RequiredVersion $rm.version -AllowClobber;
  }
  try {
    Import-Module -Name $rm.module -RequiredVersion $rm.version -ErrorAction SilentlyContinue;
  } catch {
    Write-Output -InputObject ('import of required module: {0}, version: {1}, failed. {2}' -f $rm.module, $rm.version, $_.Exception.Message);
    # if we get here, the instance is borked and will throw exceptions on all subsequent tasks.
    & shutdown @('/s', '/t', '3', '/c', 'borked powershell module library detected', '/f', '/d', '1:1');
    exit 123;
  }
}
Write-Output -InputObject ('workFolder: {0}, revision: {1}, platform: {2}, imageKey: {3}' -f $workFolder, $revision, $platform, $imageKey);

$secret = (Invoke-WebRequest -Uri ('{0}/secrets/v1/secret/project/relops/image-builder/dev' -f $env:TASKCLUSTER_PROXY_URL) -UseBasicParsing | ConvertFrom-Json).secret;
Set-AWSCredential `
  -AccessKey $secret.amazon.id `
  -SecretKey $secret.amazon.key `
  -StoreAs 'default' | Out-Null;

switch ($platform) {
  'azure' {
    Connect-AzAccount `
      -ServicePrincipal `
      -Credential (New-Object System.Management.Automation.PSCredential($secret.azure.id, (ConvertTo-SecureString `
        -String $secret.azure.key `
        -AsPlainText `
        -Force))) `
      -Tenant $secret.azure.account | Out-Null;

    $azcopyExePath = ('{0}\azcopy.exe' -f $workFolder);
    $azcopyZipPath = ('{0}\azcopy.zip' -f $workFolder);
    $azcopyZipUrl = 'https://aka.ms/downloadazcopy-v10-windows';
    if (-not (Test-Path -Path $azcopyExePath -ErrorAction SilentlyContinue)) {
      (New-Object Net.WebClient).DownloadFile($azcopyZipUrl, $azcopyZipPath);
      if (Test-Path -Path $azcopyZipPath -ErrorAction SilentlyContinue) {
        Write-Output -InputObject ('downloaded: {0} from: {1}' -f $azcopyZipPath, $azcopyZipUrl);
        Expand-Archive -Path $azcopyZipPath -DestinationPath $workFolder;
        try {
          $extractedAzcopyExePath = (@(Get-ChildItem -Path ('{0}\azcopy.exe' -f $workFolder) -Recurse -ErrorAction SilentlyContinue -Force)[0].FullName);
          Write-Output -InputObject ('extracted: {0} from: {1}' -f $extractedAzcopyExePath, $azcopyZipPath);
          Copy-Item -Path $extractedAzcopyExePath -Destination $azcopyExePath;
          if (Test-Path -Path $azcopyExePath -ErrorAction SilentlyContinue) {
            Write-Output -InputObject ('copied: {0} to: {1}' -f $extractedAzcopyExePath, $azcopyExePath);
            $env:PATH = ('{0};{1}' -f $env:PATH, $workFolder);
            [Environment]::SetEnvironmentVariable('PATH', $env:PATH, 'User');
            Write-Output -InputObject ('user env PATH set to: {0}' -f $env:PATH);
          }
        } catch {
          Write-Output -InputObject ('failed to extract azcopy from: {0}' -f $azcopyZipPath);
        }
      }
    }
  }
}

# computed target specific settings. these are probably ok as they are.
$config = (Get-Content -Path ('{0}\cloud-image-builder\config\{1}.yaml' -f $workFolder, $imageKey) -Raw | ConvertFrom-Yaml);
if (-not ($config)) {
  Write-Output -InputObject ('error: failed to find image config for {0}' -f $imageKey);
  exit 1
}
$imageArtifactDescriptorUri = ('{0}/api/index/v1/task/project.relops.cloud-image-builder.{1}.{2}.latest/artifacts/public/image-bucket-resource.json' -f $env:TASKCLUSTER_ROOT_URL, $platform, $imageKey);
try {
  $memoryStream = (New-Object System.IO.MemoryStream(, (New-Object System.Net.WebClient).DownloadData($imageArtifactDescriptorUri)));
  $streamReader = (New-Object System.IO.StreamReader(New-Object System.IO.Compression.GZipStream($memoryStream, [System.IO.Compression.CompressionMode] 'Decompress')));
  $imageArtifactDescriptor = ($streamReader.ReadToEnd() | ConvertFrom-Json);
  Write-Output -InputObject ('fetched disk image config for: {0}, from: {1}' -f $imageKey, $imageArtifactDescriptorUri);
} catch {
  Write-Output -InputObject ('error: failed to decompress or parse json from: {0}. {1}' -f $imageArtifactDescriptorUri, $_.Exception.Message);
  exit 1
}
$exportImageName = [System.IO.Path]::GetFileName($imageArtifactDescriptor.image.key);
$vhdLocalPath = ('{0}{1}{2}' -f $workFolder, ([IO.Path]::DirectorySeparatorChar), $exportImageName);

foreach ($target in @($config.target | ? { (($_.platform -eq $platform) -and $_.group -eq $group) })) {
  $bootstrapRevision = @($target.tag | ? { $_.name -eq 'sourceRevision' })[0].value;
  if ($bootstrapRevision.Length -gt 7) {
    $bootstrapRevision = $bootstrapRevision.Substring(0, 7);
  }
  $targetImageName = ('{0}-{1}-{2}-{3}' -f $target.group.Replace('rg-', ''), $imageKey, $imageArtifactDescriptor.build.revision.Substring(0, 7), $bootstrapRevision);

  switch ($platform) {
    'azure' {
      $existingImage = (Get-AzImage `
        -ResourceGroupName $target.group `
        -ImageName $targetImageName `
        -ErrorAction SilentlyContinue);
      if ($existingImage) {
        Write-Output -InputObject ('skipped machine image creation for: {0}, in group: {1}, in cloud platform: {2}. machine image exists' -f $targetImageName, $target.group, $target.platform);
        exit;
      } elseif ($enableSnapshotCopy) {
        # check if the image snapshot exists in another regional resource-group
        $targetSnapshotName = ('{0}-{1}-{2}' -f $target.group.Replace('rg-', ''), $imageKey, $imageArtifactDescriptor.build.revision.Substring(0, 7));
        foreach ($source in @($config.target | ? { (($_.platform -eq $platform) -and $_.group -ne $group) })) {
          $sourceSnapshotName = ('{0}-{1}-{2}' -f $source.group.Replace('rg-', ''), $imageKey, $imageArtifactDescriptor.build.revision.Substring(0, 7));
          $sourceSnapshot = (Get-AzSnapshot `
            -ResourceGroupName $alternateTarget.group `
            -SnapshotName $sourceSnapshotName `
            -ErrorAction SilentlyContinue);
          if ($sourceSnapshot) {
            Write-Output -InputObject ('found snapshot: {0}, in group: {1}, in cloud platform: {2}. triggering machine copy from {1} to {3}...' -f $sourceSnapshotName, $source.group, $source.platform, $target.group);

            # get/create storage account in target region
            $storageAccountName = ('{0}cib' -f $target.group.Replace('rg-', '').Replace('-', ''));
            $targetAzStorageAccount = (Get-AzStorageAccount `
              -ResourceGroupName $target.group `
              -Name $storageAccountName);
            if ($targetAzStorageAccount) {
              Write-Output -InputObject ('detected storage account: {0}, for resource group: {1}' -f $storageAccountName, $target.group);
            } else {
              $targetAzStorageAccount = (New-AzStorageAccount `
                -ResourceGroupName $target.group `
                -AccountName $storageAccountName `
                -Location $target.region.Replace(' ', '').ToLower() `
                -SkuName 'Standard_LRS');
              Write-Output -InputObject ('created storage account: {0}, for resource group: {1}' -f $storageAccountName, $target.group);
            }
            if (-not ($targetAzStorageAccount)) {
              Write-Output -InputObject ('failed to get or create az storage account: {0}' -f $storageAccountName);
              exit 1;
            }

            # get/create storage container (bucket) in target region
            $storageContainerName = ('{0}cib' -f $target.group.Replace('rg-', '').Replace('-', ''));
            $targetAzStorageContainer = (Get-AzStorageContainer `
              -Name $storageContainerName `
              -Context $targetAzStorageAccount.Context);
            if ($targetAzStorageContainer) {
              Write-Output -InputObject ('detected storage container: {0}' -f $storageContainerName);
            } else {
              $targetAzStorageContainer = (New-AzStorageContainer `
                -Name $storageContainerName `
                -Context $targetAzStorageAccount.Context `
                -Permission 'Container');
              Write-Output -InputObject ('created storage container: {0}' -f $storageContainerName);
            }
            if (-not ($targetAzStorageContainer)) {
              Write-Output -InputObject ('failed to get or create az storage container: {0}' -f $storageContainerName);
              exit 1;
            }
             
            # copy snapshot to target container (bucket)
            $sourceAzSnapshotAccess = (Grant-AzSnapshotAccess `
              -ResourceGroupName $source.group `
              -SnapshotName $sourceSnapshotName `
              -DurationInSecond 3600 `
              -Access 'Read');
            Start-AzStorageBlobCopy `
              -AbsoluteUri $sourceAzSnapshotAccess.AccessSAS `
              -DestContainer $storageContainerName `
              -DestContext $targetAzStorageAccount.Context `
              -DestBlob $targetSnapshotName;
            # todo: wrap above cmdlet in try/catch and handle exceptions
            $targetAzStorageBlobCopyState = (Get-AzStorageBlobCopyState `
              -Container $storageContainerName `
              -Blob $targetSnapshotName `
              -Context $targetAzStorageAccount.Context `
              -WaitForComplete);
            $targetAzSnapshotConfig = (New-AzSnapshotConfig `
              -AccountType 'Standard_LRS' `
              -OsType 'Windows' `
              -Location $target.region.Replace(' ', '').ToLower() `
              -CreateOption 'Import' `
              -SourceUri ('{0}{1}/{2}' -f $targetAzStorageAccount.Context.BlobEndPoint, $storageContainerName, $targetSnapshotName) `
              -StorageAccountId $targetAzStorageAccount.Id);
            $targetAzSnapshot = (New-AzSnapshot `
              -ResourceGroupName $target.group `
              -SnapshotName $targetSnapshotName `
              -Snapshot $targetAzSnapshotConfig);
            Write-Output -InputObject ('provisioning of snapshot: {0}, has state: {1}' -f $targetSnapshotName, $targetAzSnapshot.ProvisioningState.ToLower());
            $targetAzImageConfig = (New-AzImageConfig `
              -Location $target.region.Replace(' ', '').ToLower());
            $targetAzImageConfig = (Set-AzImageOsDisk `
              -Image $targetAzImageConfig `
              -OsType 'Windows' `
              -OsState 'Generalized' `
              -SnapshotId $targetAzSnapshot.Id);
            $targetAzImage = (New-AzImage `
              -ResourceGroupName $target.group `
              -ImageName $targetImageName `
              -Image $targetAzImageConfig);
            if (-not $targetAzImage) {
              Write-Output -InputObject ('provisioning of image: {0}, failed' -f $targetImageName);
              exit 1;
            }
            Write-Output -InputObject ('provisioning of image: {0}, has state: {1}' -f $targetImageName, $targetAzImage.ProvisioningState.ToLower());
            exit;
          }
        }
      }
    }
  }
  if (-not (Test-Path -Path $vhdLocalPath -ErrorAction SilentlyContinue)) {
    Get-CloudBucketResource `
      -platform $imageArtifactDescriptor.image.platform `
      -bucket $imageArtifactDescriptor.image.bucket `
      -key $imageArtifactDescriptor.image.key `
      -destination $vhdLocalPath `
      -force;
    if (Test-Path -Path $vhdLocalPath -ErrorAction SilentlyContinue) {
      Write-Output -InputObject ('download success for: {0} from: {1}/{2}/{3}' -f $vhdLocalPath, $imageArtifactDescriptor.image.platform, $imageArtifactDescriptor.image.bucket, $imageArtifactDescriptor.image.key);
    } else {
      Write-Output -InputObject ('download failure for: {0} from: {1}/{2}/{3}' -f $vhdLocalPath, $imageArtifactDescriptor.image.platform, $imageArtifactDescriptor.image.bucket, $imageArtifactDescriptor.image.key);
      exit 1;
    }
  }

  switch ($platform) {
    'azure' {
      $sku = ($target.machine.format -f $target.machine.cpu);
      if (-not (Get-AzComputeResourceSku | where { (($_.Locations -icontains $target.region.Replace(' ', '').ToLower()) -and ($_.Name -eq $sku)) })) {
        Write-Output -InputObject ('skipped image export: {0}, to region: {1}, in cloud platform: {2}. {3} is not available' -f $exportImageName, $target.region, $target.platform, $sku);
        exit 1;
      } else {
        switch -regex ($sku) {
          '^Basic_A[0-9]+$' {
            $skuFamily = 'Basic A Family vCPUs';
            break;
          }
          '^Standard_A[0-7]$' {
            $skuFamily = 'Standard A0-A7 Family vCPUs';
            break;
          }
          '^Standard_A(8|9|10|11)$' {
            $skuFamily = 'Standard A8-A11 Family vCPUs';
            break;
          }
          '^(Basic|Standard)_(B|D|E|F|H|L|M)[0-9]+m?r?$' {
            $skuFamily = '{0} {1} Family vCPUs' -f $matches[1], $matches[2];
            break;
          }
          '^(Basic|Standard)_(A|B|D|E|F|H|L|M)[0-9]+m?r?_Promo$' {
            $skuFamily = '{0} {1} Promo Family vCPUs' -f $matches[1], $matches[2];
            break;
          }
          '^(Basic|Standard)_(A|B|D|E|F|H|L|M)[0-9]+[lmt]?s$' {
            $skuFamily = '{0} {1}S Family vCPUs' -f $matches[1], $matches[2];
            break;
          }
          '^(Basic|Standard)_(A|B|D|E|F|H|L|M|P)([BC])[0-9]+r?s$' {
            $skuFamily = '{0} {1}{2}S Family vCPUs' -f $matches[1], $matches[2], $matches[3];
            break;
          }
          '^(Basic|Standard)_(A|B|D|E|F|H|L|M)[0-9]+(-(1|2|4|8|16|32|64))?m?s$' {
            $skuFamily = '{0} {1}S Family vCPUs' -f $matches[1], $matches[2];
            break;
          }
          '^(Basic|Standard)_(A|B|D|E|F|H|L|M)S[0-9]+$' {
            $skuFamily = '{0} {1}S Family vCPUs' -f $matches[1], $matches[2];
            break;
          }
          '^(Basic|Standard)_(A|B|D|E|F|H|L|M)1?[0-9]+m?_v([2-4])$' {
            $skuFamily = '{0} {1}v{2} Family vCPUs' -f $matches[1], $matches[2], $matches[3];
            break;
          }
          '^(Basic|Standard)_(A|B|D|E|F|H|L|M)?[0-9]+_v([2-4])_Promo$' {
            $skuFamily = '{0} {1}v{2} Promo Family vCPUs' -f $matches[1], $matches[2], $matches[3];
            break;
          }
          '^(Basic|Standard)_(A|B|D|E|F|H|L|M)1?[0-9]+_v([2-4])$' {
            $skuFamily = '{0} {1}v{2} Family vCPUs' -f $matches[1], $matches[2], $matches[3];
            break;
          }
          '^(Basic|Standard)_(A|B|D|E|F|H|L|M)1?[0-9]+m?s_v([2-4])$' {
            $skuFamily = '{0} {1}Sv{2} Family vCPUs' -f $matches[1], $matches[2], $matches[3];
            break;
          }
          '^(Basic|Standard)_(A|B|D|E|F|H|L|M)[0-9]+(-(1|2|4|8|16|32|64))?s_v([2-4])$' {
            $skuFamily = '{0} {1}Sv{2} Family vCPUs' -f $matches[1], $matches[2], $matches[5];
            break;
          }
          '^(Basic|Standard)_(A|B|D|E|F|H|L|M)S[0-9]+(-(1|2|4|8|16|32|64))?_v([2-4])$' {
            $skuFamily = '{0} {1}Sv{2} Family vCPUs' -f $matches[1], $matches[2], $matches[5];
            break;
          }
          '^(Basic|Standard)_(A|B|D|E|F|H|L|M)[0-9]+(-(1|2|4|8|16|32|64))?i_v([2-4])$' {
            $skuFamily = '{0} {1}Iv{2} Family vCPUs' -f $matches[1], $matches[2], $matches[5];
            break;
          }
          '^(Basic|Standard)_(A|B|D|E|F|H|L|M)[0-9]+(-(1|2|4|8|16|32|64))?is_v([2-4])$' {
            $skuFamily = '{0} {1}ISv{2} Family vCPUs' -f $matches[1], $matches[2], $matches[5];
            break;
          }
          '^(Basic|Standard)_(A|B|D|E|F|H|L|M)S[0-9]+_v([2-4])_Promo$' {
            $skuFamily = '{0} {1}Sv{2} Promo Family vCPUs' -f $matches[1], $matches[2], $matches[3];
            break;
          }
          '^(Basic|Standard)_(A|B|D|E|F|H|L|M)1?[0-9]+a_v([2-4])$' {
            $skuFamily = '{0} {1}Av{2} Family vCPUs' -f $matches[1], $matches[2], $matches[3];
            break;
          }
          '^(Basic|Standard)_(A|B|D|E|F|H|L|M)1?[0-9]+as_v([2-4])$' {
            $skuFamily = '{0} {1}ASv{2} Family vCPUs' -f $matches[1], $matches[2], $matches[3];
            break;
          }
          '^Standard_N([CV])[0-9]+r?$' {
            $skuFamily = 'Standard N{0} Family vCPUs' -f $matches[1];
            break;
          }
          '^Standard_N([CV])[0-9]+r?_Promo$' {
            $skuFamily = 'Standard N{0} Promo Family vCPUs' -f $matches[1];
            break;
          }
          '^Standard_N([DP])S[0-9]+$' {
            $skuFamily = 'Standard N{0}S Family vCPUs' -f $matches[1];
            break;
          }
          '^Standard_N([DP])[0-9]+r?s$' {
            $skuFamily = 'Standard N{0}S Family vCPUs' -f $matches[1];
            break;
          }
          '^Standard_N([CDV])[0-9]+r?s_v([2-4])$' {
            $skuFamily = 'Standard N{0}Sv{1} Family vCPUs' -f $matches[1], $matches[2];
            break;
          }
          default {
            $skuFamily = $false;
            break;
          }
        }
        if ($skuFamily) {
          Write-Output -InputObject ('mapped machine sku: {0}, to machine family: {1}' -f $sku, $skuFamily);
          $azVMUsage = @(Get-AzVMUsage -Location $target.region | ? { $_.Name.LocalizedValue -eq $skuFamily })[0];
        } else {
          Write-Output -InputObject ('failed to map machine sku: {0}, to machine family (no regex match)' -f $sku);
          $azVMUsage = $false;
          exit 1;
        }
        if (-not $azVMUsage) {
          Write-Output -InputObject ('skipped image export: {0}, to region: {1}, in cloud platform: {2}. failed to obtain vm usage for machine sku: {3}, family: {4}' -f $exportImageName, $target.region, $target.platform, $sku, $skuFamily);
          exit 1;
        } elseif ($azVMUsage.Limit -lt ($azVMUsage.CurrentValue + $target.machine.cpu)) {
          Write-Output -InputObject ('skipped image export: {0}, to region: {1}, in cloud platform: {2}. {3}/{4} cores quota in use for machine sku: {5}, family: {6}. no capacity for requested aditional {7} cores' -f $exportImageName, $target.region, $target.platform, $azVMUsage.CurrentValue, $azVMUsage.Limit, $sku, $skuFamily, $target.machine.cpu);
          exit 123;
        } else {
          Write-Output -InputObject ('quota usage check: usage limit: {0}, usage current value: {1}, core request: {2}, for machine sku: {3}, family: {4}' -f $azVMUsage.Limit, $azVMUsage.CurrentValue, $target.machine.cpu, $sku, $skuFamily);
          try {
            Write-Output -InputObject ('begin image export: {0}, to region: {1}, in cloud platform: {2}' -f $exportImageName, $target.region, $target.platform);
            switch ($target.hostname.slug.type) {
              'uuid' {
                $resourceId = (([Guid]::NewGuid()).ToString().Substring((36 - $target.hostname.slug.length)));
                $instanceName = ($target.hostname.format -f $resourceId);
                break;
              }
              default {
                $resourceId = (([Guid]::NewGuid()).ToString().Substring(24));
                $instanceName = ('vm-{0}' -f $resourceId);
                break;
              }
            }
            $tags = @{
              'diskImageBuildDate' = $imageArtifactDescriptor.build.date;
              'diskImageBuildTime' = $imageArtifactDescriptor.build.time;
              'diskImageBuildRevision' = $imageArtifactDescriptor.build.revision;
              'machineImageBuildDate' = (Get-Date -UFormat '+%Y-%m-%d');
              'machineImageBuildTime' = (Get-Date -UFormat '+%Y-%m-%dT%H:%M:%S%Z');
              'machineImageBuildRevision' = $revision;
              'imageKey' = $imageKey;
              'resourceId' = $resourceId;
              'sourceIso' = ([System.IO.Path]::GetFileName($config.iso.source.key))
            };
            foreach ($tag in $target.tag) {
              $tags[$tag.name] = $tag.value;
            }

            # check (again) that another task hasn't already created the image
            $existingImage = (Get-AzImage `
              -ResourceGroupName $target.group `
              -ImageName $targetImageName `
              -ErrorAction SilentlyContinue);
            if ($existingImage) {
              Write-Output -InputObject ('skipped machine image creation for: {0}, in group: {1}, in cloud platform: {2}. machine image exists' -f $targetImageName, $target.group, $target.platform);
              exit;
            }

            $newCloudInstanceInstantiationAttempts = 0;
            do {
              # todo: get instance screenshots
              New-CloudInstanceFromImageExport `
                -platform $target.platform `
                -localImagePath $vhdLocalPath `
                -targetResourceId $resourceId `
                -targetResourceGroupName $target.group `
                -targetResourceRegion $target.region `
                -targetInstanceMachineVariantFormat $target.machine.format `
                -targetInstanceCpuCount $target.machine.cpu `
                -targetInstanceRamGb $target.machine.ram `
                -targetInstanceName $instanceName `
                -targetInstanceDisks @($target.disk | % {@{ 'Variant' = $_.variant; 'SizeInGB' = $_.size; 'Os' = $_.os }}) `
                -targetInstanceTags $tags `
                -targetVirtualNetworkName $target.network.name `
                -targetVirtualNetworkAddressPrefix $target.network.prefix `
                -targetVirtualNetworkDnsServers $target.network.dns `
                -targetSubnetName $target.network.subnet.name `
                -targetSubnetAddressPrefix $target.network.subnet.prefix `
                -targetFirewallConfigurationName $target.network.flow.name `
                -targetFirewallRules $target.network.flow.rules;



              $newCloudInstanceInstantiationAttempts += 1;
              $azVm = (Get-AzVm -ResourceGroupName $target.group -Name $instanceName -ErrorAction SilentlyContinue);
              if ($azVm) {
                if (@('Succeeded', 'Failed') -contains $azVm.ProvisioningState) {
                  Write-Output -InputObject ('provisioning of vm: {0}, {1} on attempt: {2}' -f $instanceName, $azVm.ProvisioningState.ToLower(), $newCloudInstanceInstantiationAttempts);
                } else {
                  Write-Output -InputObject ('provisioning of vm: {0}, in progress with state: {1} on attempt: {2}' -f $instanceName, $azVm.ProvisioningState.ToLower(), $newCloudInstanceInstantiationAttempts);
                  Start-Sleep -Seconds 60
                }
              } else {
                # if we reach here, we most likely hit an azure quota exception which we may recover from when some quota becomes available.
                # retry until within 30 minutes of task expiry time, then exit with a code that will prompt a task retry
                $deleteNiAttempts = 0;
                $deleteIpAttempts = 0;
                $deleteDiskAttempts = 0;
                # instance instantiation failures leave behind a disk, public ip and network interface which need to be deleted.
                # the deletion will fail if the failed instance deletion is not complete.
                # retry for a while before giving up.
                do {
                  try {
                    $azNetworkInterface = (Get-AzNetworkInterface `
                      -ResourceGroupName $target.group `
                      -Name ('ni-{0}' -f $resourceId) `
                      -ErrorAction SilentlyContinue);
                    if ($azNetworkInterface) {
                      $deleteNiAttempts += 1;
                      Write-Output -InputObject ('removing aborted AzNetworkInterface {0} / {1} / {2}. attempt {3}...' -f $azNetworkInterface.Location, $azNetworkInterface.ResourceGroupName, $azNetworkInterface.Name, $deleteNiAttempts);
                      if (Remove-AzNetworkInterface `
                        -ResourceGroupName $azNetworkInterface.ResourceGroupName `
                        -Name $azNetworkInterface.Name `
                        -Force) {
                        Write-Output -InputObject ('removed aborted AzNetworkInterface {0} / {1} / {2} on attempt {3}' -f $azNetworkInterface.Location, $azNetworkInterface.ResourceGroupName, $azNetworkInterface.Name, $deleteNiAttempts);
                      } else {
                        Write-Output -InputObject ('failed to remove aborted AzNetworkInterface {0} / {1} / {2} on attempt {3}' -f $azNetworkInterface.Location, $azNetworkInterface.ResourceGroupName, $azNetworkInterface.Name, $deleteNiAttempts);
                        if ($deleteNiAttempts -gt 10) {
                          Write-Output -InputObject ('deletion of AzNetworkInterface: {0}, failed on attempt: {1}. passing control to task retry logic...' -f ('ni-{0}' -f $resourceId), $deleteNiAttempts);
                          exit 123;
                        }
                      }
                    }
                  } catch {
                    Write-Output -InputObject ('failed to remove aborted AzNetworkInterface {0} / {1} / {2}. {3}' -f $target.region, $target.group, ('ni-{0}' -f $resourceId), $_.Exception.Message);
                  }
                  try {
                    $azPublicIpAddress = (Get-AzPublicIpAddress `
                      -ResourceGroupName $target.group `
                      -Name ('ip-{0}' -f $resourceId) `
                      -ErrorAction SilentlyContinue);
                    if ($azPublicIpAddress) {
                      $deleteIpAttempts += 1;
                      Write-Output -InputObject ('removing aborted AzPublicIpAddress {0} / {1} / {2}. attempt {3}...' -f $azPublicIpAddress.Location, $azPublicIpAddress.ResourceGroupName, $azPublicIpAddress.Name, $deleteIpAttempts);
                      if (Remove-AzPublicIpAddress `
                        -ResourceGroupName $azPublicIpAddress.ResourceGroupName `
                        -Name $azPublicIpAddress.Name `
                        -Force) {
                        Write-Output -InputObject ('removed aborted AzPublicIpAddress {0} / {1} / {2} on attempt {3}' -f $azPublicIpAddress.Location, $azPublicIpAddress.ResourceGroupName, $azPublicIpAddress.Name, $deleteIpAttempts);
                      } else {
                        Write-Output -InputObject ('failed to remove aborted AzPublicIpAddress {0} / {1} / {2} on attempt {3}' -f $azPublicIpAddress.Location, $azPublicIpAddress.ResourceGroupName, $azPublicIpAddress.Name, $deleteIpAttempts);
                        if ($deleteIpAttempts -gt 10) {
                          Write-Output -InputObject ('deletion of AzPublicIpAddress: {0}, failed on attempt: {1}. passing control to task retry logic...' -f ('ip-{0}' -f $resourceId), $deleteIpAttempts);
                          exit 123;
                        }
                      }
                    }
                  } catch {
                    Write-Output -InputObject ('failed to remove aborted AzPublicIpAddress {0} / {1} / {2}. {3}' -f $target.region, $target.group, ('ip-{0}' -f $resourceId), $_.Exception.Message);
                  }
                  try {
                    $azDisk = (Get-AzDisk `
                      -ResourceGroupName $target.group `
                      -DiskName ('disk-{0}' -f $resourceId) `
                      -ErrorAction SilentlyContinue);
                    if ($azDisk) {
                      $deleteDiskAttempts += 1;
                      Write-Output -InputObject ('removing aborted AzDisk {0} / {1} / {2}. attempt {3}...' -f $azDisk.Location, $azDisk.ResourceGroupName, $azDisk.Name, $deleteDiskAttempts);
                      if (Remove-AzDisk `
                        -ResourceGroupName $azDisk.ResourceGroupName `
                        -DiskName $azDisk.Name `
                        -Force) {
                        Write-Output -InputObject ('removed aborted AzDisk {0} / {1} / {2} on attempt {3}' -f $azDisk.Location, $azDisk.ResourceGroupName, $azDisk.Name, $deleteDiskAttempts);
                      } else {
                        Write-Output -InputObject ('failed to remove aborted AzDisk {0} / {1} / {2} on attempt {3}' -f $azDisk.Location, $azDisk.ResourceGroupName, $azDisk.Name, $deleteDiskAttempts);
                        if ($deleteDiskAttempts -gt 10) {
                          Write-Output -InputObject ('deletion of AzDisk: {0}, failed on attempt: {1}. passing control to task retry logic...' -f ('disk-{0}' -f $resourceId), $deleteDiskAttempts);
                          exit 123;
                        }
                      }
                    }
                  } catch {
                    Write-Output -InputObject ('failed to remove aborted AzDisk {0} / {1} / {2}. {3}' -f $target.region, $target.group, ('disk-{0}' -f $resourceId), $_.Exception.Message);
                  }
                  Start-Sleep -Seconds (Get-Random -Minimum 10 -Maximum 60)
                } while ((Get-AzNetworkInterface -ResourceGroupName $target.group -Name ('ni-{0}' -f $resourceId) -ErrorAction SilentlyContinue) -or (Get-AzPublicIpAddress -ResourceGroupName $target.group -Name ('ip-{0}' -f $resourceId) -ErrorAction SilentlyContinue) -or (Get-AzDisk -ResourceGroupName $target.group -DiskName ('disk-{0}' -f $resourceId) -ErrorAction SilentlyContinue))
                try {
                  $taskDefinition = (Invoke-WebRequest -Uri ('{0}/api/queue/v1/task/{1}' -f $env:TASKCLUSTER_ROOT_URL, $env:TASK_ID) -UseBasicParsing | ConvertFrom-Json);
                  [DateTime] $taskStart = $taskDefinition.created;
                  [DateTime] $taskExpiry = $taskStart.AddSeconds($taskDefinition.payload.maxRunTime);
                  if ($taskExpiry -lt (Get-Date).AddMinutes(30)) {
                    Write-Output -InputObject ('provisioning of vm: {0}, failed on attempt: {1}. passing control to task retry logic...' -f $instanceName, $newCloudInstanceInstantiationAttempts);
                    exit 123;
                  }
                } catch {
                  Write-Output -InputObject ('failed to determine task expiry time using root url {0} and task id: {1}. {2}' -f $env:TASKCLUSTER_ROOT_URL, $env:TASK_ID, $_.Exception.Message);
                }
                $sleepInSeconds = (Get-Random -Minimum (3 * 60) -Maximum (10 * 60));
                Write-Output -InputObject ('provisioning of vm: {0}, failed on attempt: {1}. retrying in {2:1} minutes...' -f $instanceName, $newCloudInstanceInstantiationAttempts, ($sleepInSeconds / 60));
                Start-Sleep -Seconds $sleepInSeconds;
              }
            } until (@('Succeeded', 'Failed') -contains $azVm.ProvisioningState)
            Write-Output -InputObject ('end image export: {0} to: {1} cloud platform' -f $exportImageName, $target.platform);

            if ($azVm -and ($azVm.ProvisioningState -eq 'Succeeded')) {
              Write-Output -InputObject ('begin image import: {0} in region: {1}, cloud platform: {2}' -f $targetImageName, $target.region, $target.platform);
              $successfulOccRunDetected = $false;

              $bootstrapOrg = @($target.tag | ? { $_.name -eq 'sourceOrganisation' })[0].value;
              $bootstrapRepo = @($target.tag | ? { $_.name -eq 'sourceRepository' })[0].value;
              $bootstrapRef = @($target.tag | ? { $_.name -eq 'sourceRevision' })[0].value;
              $bootstrapScript = @($target.tag | ? { $_.name -eq 'sourceScript' })[0].value;
              $bootstrapUrl = ('https://raw.githubusercontent.com/{0}/{1}/{2}/{3}' -f $bootstrapOrg, $bootstrapRepo, $bootstrapRef, $bootstrapScript);
              $workerDomain = $target.group.Replace(('rg-{0}-' -f $target.region.Replace(' ', '-').ToLower()), '');
              $workerVariant = ('{0}-{1}' -f $imageKey, $target.platform);
              $accessToken = ($secret.accessToken.production."$($target.platform)"."$workerDomain"."$workerVariant");
              if (($accessToken) -and ($accessToken.Length -eq 44)) {
                Write-Output -InputObject ('access-token determined for client-id {0}/{1}/{2}' -f $target.platform, $workerDomain, $workerVariant)
              } else {
                Write-Output -InputObject ('failed to determine access-token for client-id {0}/{1}/{2}' -f $target.platform, $workerDomain, $workerVariant);
                try {
                  Remove-AzVm `
                    -ResourceGroupName $target.group `
                    -Name $instanceName `
                    -Force;
                  Write-Output -InputObject ('instance: {0}, deletion appears successful' -f $instanceName);
                } catch {
                  Write-Output -InputObject ('instance: {0}, deletion threw exception. {1}' -f $instanceName, $_.Exception.Message);
                }
                exit 123;
              }

              if ($config.image.architecture -eq 'x86-64') {
                $bootstrapPath = ('{0}\bootstrap.ps1' -f $env:Temp)
                (New-Object Net.WebClient).DownloadFile($bootstrapUrl, $bootstrapPath);
                if (Test-Path -Path $bootstrapPath -ErrorAction SilentlyContinue) {
                  Write-Output -InputObject ('downloaded {0} from {1}' -f $bootstrapPath, $bootstrapUrl);
                } else {
                  Write-Output -InputObject ('failed to download {0} from {1}' -f $bootstrapPath, $bootstrapUrl);
                  try {
                    Remove-AzVm `
                      -ResourceGroupName $target.group `
                      -Name $instanceName `
                      -Force;
                    Write-Output -InputObject ('instance: {0}, deletion appears successful' -f $instanceName);
                  } catch {
                    Write-Output -InputObject ('instance: {0}, deletion threw exception. {1}' -f $instanceName, $_.Exception.Message);
                  }
                  exit 1;
                }

                # set secrets in the instance registry. this is only needed if we aren't using worker-runner
                #Set-Content -Path ('{0}\setsecrets.ps1' -f $env:Temp) -Value ('New-Item -Path "HKLM:\SOFTWARE" -Name "Mozilla" -Force; New-Item -Path "HKLM:\SOFTWARE\Mozilla" -Name "GenericWorker" -Force; Set-ItemProperty -Path "HKLM:\SOFTWARE\Mozilla\GenericWorker" -Name "clientId" -Value "{0}/{1}/{2}" -Type "String"; Set-ItemProperty -Path "HKLM:\SOFTWARE\Mozilla\GenericWorker" -Name "accessToken" -Value "{3}" -Type "String"' -f $target.platform, $workerDomain, $workerVariant, $accessToken);
                #$setSecretsCommandResult = (Invoke-AzVMRunCommand `
                #  -ResourceGroupName $target.group `
                #  -VMName $instanceName `
                #  -CommandId 'RunPowerShellScript' `
                #  -ScriptPath ('{0}\setsecrets.ps1' -f $env:Temp));
                #Write-Output -InputObject ('set secrets {0} on instance: {1} in region: {2}, cloud platform: {3}' -f $(if ($setSecretsCommandResult -and $setSecretsCommandResult.Status) { $setSecretsCommandResult.Status.ToLower() } else { 'status unknown' }), $instanceName, $target.region, $target.platform);
                #Write-Output -InputObject ('set secrets std out: {0}' -f $setSecretsCommandResult.Value[0].Message);
                #Write-Output -InputObject ('set secrets std err: {0}' -f $setSecretsCommandResult.Value[1].Message);
                #Remove-Item -Path ('{0}\setsecrets.ps1' -f $env:Temp);

                $bootstrapTriggerCommandResult = (Invoke-AzVMRunCommand `
                  -ResourceGroupName $target.group `
                  -VMName $instanceName `
                  -CommandId 'RunPowerShellScript' `
                  -ScriptPath $bootstrapPath); #-Parameter @{"arg1" = "var1";"arg2" = "var2"}
                Write-Output -InputObject ('bootstrap trigger {0} on instance: {1} in region: {2}, cloud platform: {3}' -f $(if ($bootstrapTriggerCommandResult -and $bootstrapTriggerCommandResult.Status) { $bootstrapTriggerCommandResult.Status.ToLower() } else { 'status unknown' }), $instanceName, $target.region, $target.platform);
                Write-Output -InputObject ('bootstrap trigger std out: {0}' -f $bootstrapTriggerCommandResult.Value[0].Message);
                Write-Output -InputObject ('bootstrap trigger std err: {0}' -f $bootstrapTriggerCommandResult.Value[1].Message);

                if ($bootstrapTriggerCommandResult.Status -eq 'Succeeded') {
                  Set-Content -Path ('{0}\verifyBootstrapCompletion.ps1' -f $env:Temp) -Value 'if ((Get-ItemProperty -Path "HKLM:\SOFTWARE\Mozilla\ronin_puppet" -Name "last_run_exit").last_run_exit -in @(0, 2)) { Write-Output -InputObject "completed" } else { Write-Output -InputObject "incomplete" }';
                  $verifyBootstrapCompletionCommandOutput = '';
                  $verifyBootstrapCompletionIteration = 0;
                  do {
                    $verifyBootstrapCompletionResult = (Invoke-AzVMRunCommand `
                      -ResourceGroupName $target.group `
                      -VMName $instanceName `
                      -CommandId 'RunPowerShellScript' `
                      -ScriptPath ('{0}\verifyBootstrapCompletion.ps1' -f $env:Temp) `
                      -ErrorAction SilentlyContinue);
                    Write-Output -InputObject ('verify bootstrap completion(iteration {0}) command {1} on instance: {2} in region: {3}, cloud platform: {4}' -f $verifyBootstrapCompletionIteration, $(if ($verifyBootstrapCompletionResult -and $verifyBootstrapCompletionResult.Status) { $verifyBootstrapCompletionResult.Status.ToLower() } else { 'status unknown' }), $instanceName, $target.region, $target.platform);
                    if ($verifyBootstrapCompletionResult.Value) {
                      $verifyBootstrapCompletionCommandOutput = $verifyBootstrapCompletionResult.Value[0].Message;
                      Write-Output -InputObject ('verify bootstrap completion(iteration {0}) std out: {1}' -f $verifyBootstrapCompletionIteration, $verifyBootstrapCompletionResult.Value[0].Message);
                      Write-Output -InputObject ('verify bootstrap completion(iteration {0}) std err: {1}' -f $verifyBootstrapCompletionIteration, $verifyBootstrapCompletionResult.Value[1].Message);
                    } else {
                      Write-Output -InputObject ('verify bootstrap completion(iteration {0}) command did not return a value' -f $verifyBootstrapCompletionIteration);
                    }
                    if ($verifyBootstrapCompletionCommandOutput -match 'completed') {
                      Write-Output -InputObject ('verify bootstrap completion(iteration {0}) detected bootstrap completion on: {1}' -f $verifyBootstrapCompletionIteration, $instanceName);
                      $successfulOccRunDetected = $true;
                    } else {
                      Write-Output -InputObject ('verify bootstrap completion(iteration {0}) awaiting bootstrap completion on: {1}' -f $verifyBootstrapCompletionIteration, $instanceName);
                      Start-Sleep -Seconds 30;
                    }
                    $verifyBootstrapCompletionIteration += 1;
                  } until ($verifyBootstrapCompletionCommandOutput -match 'completed')
                  Remove-Item -Path ('{0}\verifyBootstrapCompletion.ps1' -f $env:Temp);
                }
              } else {
                # bootstrap over winrm for architectures that do not have an azure vm agent

                # determine public ip of remote azure instance
                try {
                  $azPublicIpAddress = (Get-AzPublicIpAddress `
                    -ResourceGroupName $target.group `
                    -Name ('ip-{0}' -f $resourceId) `
                    -ErrorAction SilentlyContinue);
                  if ($azPublicIpAddress -and $azPublicIpAddress.IpAddress) {
                    Write-Output -InputObject ('public ip address : "{0}", determined for: ip-{1}' -f $azPublicIpAddress.IpAddress, $resourceId);
                  } else {
                    Write-Output -InputObject ('error: failed to determine public ip address for: ip-{0}' -f $resourceId);
                    exit 1;
                  }
                } catch {
                  Write-Output -InputObject ('error: failed to determine public ip address for: ip-{0}. {1}' -f $resourceId, $_.Exception.Message);
                  exit 1;
                }

                # determine administrator password of remote azure instance
                $imageUnattendFileUri = ('{0}/api/index/v1/task/project.relops.cloud-image-builder.{1}.{2}.latest/artifacts/public/unattend.xml' -f $env:TASKCLUSTER_ROOT_URL, $platform, $imageKey);
                try {
                  $memoryStream = (New-Object System.IO.MemoryStream(, (New-Object System.Net.WebClient).DownloadData($imageUnattendFileUri)));
                  $streamReader = (New-Object System.IO.StreamReader(New-Object System.IO.Compression.GZipStream($memoryStream, [System.IO.Compression.CompressionMode] 'Decompress')));
                  [xml]$imageUnattendFileXml = [xml]$streamReader.ReadToEnd();
                  Write-Output -InputObject ('fetched disk image unattend file for: {0}, from: {1}' -f $imageKey, $imageUnattendFileUri);
                } catch {
                  Write-Output -InputObject ('error: failed to decompress or parse xml from: {0}. {1}' -f $imageUnattendFileUri, $_.Exception.Message);
                  exit 1;
                }
                $imagePassword = $imageUnattendFileXml.unattend.settings.component.UserAccounts.AdministratorPassword.Value.InnerText;
                if ($imagePassword) {
                  Write-Output -InputObject ('image password with length: {0}, extracted from: {1}' -f $imagePassword.Length, $imageUnattendFileUri);
                } else {
                  Write-Output -InputObject ('error: failed to extract image password from: {0}' -f $imageUnattendFileUri);
                  exit 1;
                }
                $credential = (New-Object `
                  -TypeName 'System.Management.Automation.PSCredential' `
                  -ArgumentList @('.\Administrator', (ConvertTo-SecureString $imagePassword -AsPlainText -Force)));

                # modify security group of remote azure instance to allow winrm from public ip of local task instance
                try {
                  $taskRunnerIpAddress = (New-Object Net.WebClient).DownloadString('http://169.254.169.254/latest/meta-data/public-ipv4');
                  $azNetworkSecurityGroup = (Get-AzNetworkSecurityGroup -Name $target.network.flow.name);
                  $existingWinrmAzNetworkSecurityRuleConfig = (Get-AzNetworkSecurityRuleConfig -NetworkSecurityGroup $azNetworkSecurityGroup -Name 'allow-winrm');
                  $allowedIps = @(@($taskRunnerIpAddress) + $existingWinrmAzNetworkSecurityRuleConfig.SourceAddressPrefix);
                  $setAzNetworkSecurityRuleConfigResult = (Set-AzNetworkSecurityRuleConfig `
                    -Name 'allow-winrm' `
                    -NetworkSecurityGroup $azNetworkSecurityGroup `
                    -SourceAddressPrefix $allowedIps);
                  if ($setAzNetworkSecurityRuleConfigResult.ProvisioningState -eq 'Succeeded') {
                    $updatedIps = @($setAzNetworkSecurityRuleConfigResult.SecurityRules | ? { $_.Name -eq 'allow-winrm' })[0].SourceAddressPrefix;
                    Write-Output -InputObject ('winrm firewall configuration at: {0}/allow-winrm, modified to allow inbound from: {1}' -f $target.network.flow.name, [String]::Join(', ', $updatedIps));
                  } else {
                    Write-Output -InputObject ('error: failed to modify winrm firewall configuration. provisioning state: {0}' -f $setAzNetworkSecurityRuleConfigResult.ProvisioningState);
                    exit 1;
                  }
                } catch {
                  Write-Output -InputObject ('error: failed to modify winrm firewall configuration. {0}' -f $_.Exception.Message);
                  exit 1;
                }

                # enable remoting and add remote azure instance to trusted host list
                try {
                  #Enable-PSRemoting -SkipNetworkProfileCheck -Force
                  #Write-Output -InputObject 'powershell remoting enabled for session';
                  $trustedHostsPreBootstrap = (Get-Item -Path 'WSMan:\localhost\Client\TrustedHosts').Value;
                  Write-Output -InputObject ('local wsman trusted hosts list detected as: "{0}"' -f $trustedHostsPreBootstrap);
                  $trustedHostsForBootstrap = $(if (($trustedHostsPreBootstrap) -and ($trustedHostsPreBootstrap.Length -gt 0)) { ('{0},{1}' -f $trustedHostsPreBootstrap, $azPublicIpAddress.IpAddress) } else { $azPublicIpAddress.IpAddress });
                  #Set-Item -Path 'WSMan:\localhost\Client\TrustedHosts' -Value $trustedHostsForBootstrap -Force;
                  & winrm @('set', 'winrm/config/client', ('@{{TrustedHosts="{0}"}}' -f $trustedHostsForBootstrap));
                  Write-Output -InputObject ('local wsman trusted hosts list updated to: "{0}"' -f (Get-Item -Path 'WSMan:\localhost\Client\TrustedHosts').Value);
                } catch {
                  Write-Output -InputObject ('error: failed to modify winrm firewall configuration. {0}' -f $_.Exception.Message);
                  exit 1;
                }

                # run remote bootstrap scripts over winrm
                try {
                  Invoke-Command -ComputerName $azPublicIpAddress.IpAddress -Credential $credential -ScriptBlock {

                    # todo:
                    # - set secrets in the instance registry
                    # - rename host
                    # - run bootstrap
                    # - halt system

                    Get-UICulture
                  }
                } catch {
                  Write-Output -InputObject ('error: failed to execute bootstrap commands over winrm. {0}' -f $_.Exception.Message);
                  exit 1;
                }

                # modify azure security group to remove public ip of task instance from winrm exceptions
                $allowedIps = @($target.network.flow.rules | ? { $_.name -eq 'allow-winrm' })[0].sourceAddressPrefix
                $setAzNetworkSecurityRuleConfigResult = (Set-AzNetworkSecurityRuleConfig `
                  -Name 'allow-winrm' `
                  -NetworkSecurityGroup $azNetworkSecurityGroup `
                  -SourceAddressPrefix $allowedIps);
                if ($setAzNetworkSecurityRuleConfigResult.ProvisioningState -eq 'Succeeded') {
                  $updatedIps = @($setAzNetworkSecurityRuleConfigResult.SecurityRules | ? { $_.Name -eq 'allow-winrm' })[0].SourceAddressPrefix;
                  Write-Output -InputObject ('winrm firewall configuration at: {0}/allow-winrm, reverted to allow inbound from: {1}' -f $target.network.flow.name, [String]::Join(', ', $updatedIps));
                } else {
                  Write-Output -InputObject ('error: failed to revert winrm firewall configuration. provisioning state: {0}' -f $setAzNetworkSecurityRuleConfigResult.ProvisioningState);
                }

                #Set-Item -Path 'WSMan:\localhost\Client\TrustedHosts' -Value $(if (($trustedHostsPreBootstrap) -and ($trustedHostsPreBootstrap.Length -gt 0)) { $trustedHostsPreBootstrap } else { '' }) -Force;
                & winrm @('set', 'winrm/config/client', ('@{{TrustedHosts="{0}"}}' -f $trustedHostsPreBootstrap))
                Write-Output -InputObject ('local wsman trusted hosts list reverted to: "{0}"' -f (Get-Item -Path 'WSMan:\localhost\Client\TrustedHosts').Value);
              }

              # check (again) that another task hasn't already created the image
              $existingImage = (Get-AzImage `
                -ResourceGroupName $target.group `
                -ImageName $targetImageName `
                -ErrorAction SilentlyContinue);
              if ($existingImage) {
                Write-Output -InputObject ('skipped machine image creation for: {0}, in group: {1}, in cloud platform: {2}. machine image exists' -f $targetImageName, $target.group, $target.platform);
                exit;
              }

              if ($successfulOccRunDetected -or ($config.image.architecture -ne 'x86-64')) {
                New-CloudImageFromInstance `
                  -platform $target.platform `
                  -resourceGroupName $target.group `
                  -region $target.region `
                  -instanceName $instanceName `
                  -imageName $targetImageName;
                  #-imageTags $tags; # todo: tag image when azure ps isn't broken
                try {
                  $azImage = (Get-AzImage `
                    -ResourceGroupName $target.group `
                    -ImageName $targetImageName `
                    -ErrorAction SilentlyContinue);
                  if ($azImage) {
                    Write-Output -InputObject ('image: {0}, creation appears successful in region: {1}, cloud platform: {2}' -f $targetImageName, $target.region, $target.platform);
                  } else {
                    Write-Output -InputObject ('image: {0}, creation appears unsuccessful in region: {1}, cloud platform: {2}' -f $targetImageName, $target.region, $target.platform);
                  }
                } catch {
                  Write-Output -InputObject ('image: {0}, fetch threw exception in region: {1}, cloud platform: {2}. {3}' -f $targetImageName, $target.region, $target.platform, $_.Exception.Message);
                }
                try {
                  $azVm = (Get-AzVm `
                    -ResourceGroupName $target.group `
                    -Name $instanceName `
                    -Status `
                    -ErrorAction SilentlyContinue);
                  if (($azVm) -and (@($azVm.Statuses | ? { ($_.Code -eq 'OSState/generalized') -or ($_.Code -eq 'PowerState/deallocated') }).Length -eq 2)) {
                    # create a snapshot
                    # todo: move this functionality to posh-minions-managed
                    $azVm = (Get-AzVm `
                      -ResourceGroupName $target.group `
                      -Name $instanceName `
                      -ErrorAction SilentlyContinue);
                    if ($azVm -and $azVm.StorageProfile.OsDisk.Name) {
                      $azDisk = (Get-AzDisk `
                        -ResourceGroupName $target.group `
                        -DiskName $azVm.StorageProfile.OsDisk.Name);
                      if ($azDisk -and $azDisk[0].Id) {
                        $azSnapshotConfig = (New-AzSnapshotConfig `
                          -SourceUri $azDisk[0].Id `
                          -CreateOption 'Copy' `
                          -Location $target.region.Replace(' ', '').ToLower());
                        $azSnapshot = (New-AzSnapshot `
                          -ResourceGroupName $target.group `
                          -Snapshot $azSnapshotConfig `
                          -SnapshotName $targetImageName);
                      } else {
                        Write-Output -InputObject ('provisioning of snapshot: {0}, from instance: {1}, skipped due to undetermined osdisk id' -f $targetImageName, $instanceName);
                      }
                    } else {
                      Write-Output -InputObject ('provisioning of snapshot: {0}, from instance: {1}, skipped due to undetermined osdisk name' -f $targetImageName, $instanceName);
                    }
                    Write-Output -InputObject ('provisioning of snapshot: {0}, from instance: {1}, has state: {2}' -f $targetImageName, $instanceName, $azSnapshot.ProvisioningState.ToLower());
                  } else {
                    Write-Output -InputObject ('provisioning of snapshot: {0}, from instance: {1}, skipped due to undetermined vm state' -f $targetImageName, $instanceName);
                  }
                } catch {
                  Write-Output -InputObject ('provisioning of snapshot: {0}, from instance: {1}, threw exception. {2}' -f $targetImageName, $instanceName, $_.Exception.Message);
                } finally {
                  try {
                    Remove-AzVm `
                      -ResourceGroupName $target.group `
                      -Name $instanceName `
                      -AsJob `
                      -Force;
                    Write-Output -InputObject ('instance: {0}, deletion appears successful' -f $instanceName);
                  } catch {
                    Write-Output -InputObject ('instance: {0}, deletion threw exception. {1}' -f $instanceName, $_.Exception.Message);
                  }
                }
              }
              Write-Output -InputObject ('end image import: {0} in region: {1}, cloud platform: {2}' -f $targetImageName, $target.region, $target.platform);
            } else {
              Write-Output -InputObject ('skipped image import: {0} in region: {1}, cloud platform: {2}' -f $targetImageName, $target.region, $target.platform);
              exit 1;
            }
          } catch {
            Write-Output -InputObject ('error: failure in image export: {0}, to region: {1}, in cloud platform: {2}. {3}' -f $exportImageName, $target.region, $target.platform, $_.Exception.Message);
            throw;
            exit 1;
          }
        }
      }
    }
  }
}