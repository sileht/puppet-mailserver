
class mailserver (
  Array[String] $domains,
  # Array[Stdlib::Compat::Ip_Address] $mynetworks,
  Array[String] $mynetworks,
  $accounts,
  $aliases,
  String $doveadm_password,
  String $postmaster_address,
  String $sync_dest,
  Stdlib::Compat::Absolute_Path $ssl_ca,
  Stdlib::Compat::Absolute_Path $ssl_cert,
  Stdlib::Compat::Absolute_Path $ssl_key,
  Boolean $disable_plaintext_auth = true,
  Boolean $use_solr_indexer = false,
  Array[String] $rmilter_recipients_whitelist = [],
  Array[String] $rmilter_spamd_whitelist = [],
  Hash $opendkim_keys = {},
  Hash $postmap_datas = {},
  Hash $postfix_options = {},
  Boolean $postfix_dane_enabled = true,
  Stdlib::Compat::Absolute_Path $virtual_aliases_file_path = "/etc/aliases",
  $relay_domains = undef,
  String $transports = "",
  Integer $imap_max_userip_connections = 10,
  Array[String] $redis_servers = undef,
  Boolean $clamav = true,
){

  validate_rmilter_recipients_whitelist{$rmilter_recipients_whitelist:}
  validate_legacy("String", "validate_re", $postmaster_address, ['^.*@.*\..*'])

  ensure_resource("apt::source", "rspamd", {
    "location" => "http://rspamd.com/apt-stable/",
    "repos" => "main",
    "release" => $::lsbdistcodename,
    "include" => {"src" => false},
    #"key" => {
    #  "id" => "3FA347D5E599BE4595CA2576FFA232EDBF21E25E",
    #  "source" => "http://rspamd.com/apt/gpg.key",
    #}
  })

  $all_postfix_options = merge({
    'max_idle' => '1h',
    'maximal_queue_lifetime' => '10d',
    'mailbox_size_limit' => '0',
    'message_size_limit' => '100240000',
  }, $postfix_options)

  $all_postmap_datas = merge({
    "sender_access" => "",
    "recipient_access" => "",
    "recipient_bcc" => "",
  }, $postmap_datas)

  group{'vmail': gid => 2000}
  user{'vmail':
    uid        => 2000,
    gid        => 2000,
    managehome => false,
    shell      => "/bin/bash",
    home       => "/var/mail",
    require    => Group['vmail'],
  } -> Package <| tag == 'mailpackages' |>

  Package <| tag == 'mailpackages' |> ->
  user{['postfix', 'dovecot']:
    groups     => 'ssl-cert',
  } -> Service <| tag == 'mailservices' |>

  ensure_packages(['ssl-cert'])

  Package <| title == 'ssl-cert' |> ->
  Package <| tag == 'mailpackages' |> ->
  file{'/var/mail':
    # ensure => directory,
    owner => 'vmail',
    group => 'vmail',
  } -> Service <| tag == 'mailservices' |>

  package{[
    'dovecot-imapd', 'dovecot-managesieved', 'dovecot-lmtpd',
    'dovecot-core', 'dovecot-antispam',
    'imapfilter',
    'rspamd', 'rmilter',
    'opendkim-tools',
    'postfix', 'postfix-pcre',
    'libnet-ident-perl', 'libio-socket-ssl-perl', 'libdbi-perl',
    ]: tag => 'mailpackages'
  }
  service{['postfix', 'dovecot', 'rspamd']:
    ensure  => running,
    enable  => true,
    tag     => "mailservices",
  }

  if $clamav {
    package{['clamav-daemon', 'clamav-unofficial-sigs', 'clamdscan']:
      ensure => present,
      tag    => 'mailpackages',
    }
    service{['clamav-daemon', 'clamav-freshclam']:
      ensure  => running,
      enable  => $clamav,
      tag     => "mailservices",
    }
  } else {
    package{['clamav-daemon', 'clamav-unofficial-sigs', 'clamdscan']:
      ensure => purged,
      tag    => 'mailpackages',
    }
    service{['clamav-daemon', 'clamav-freshclam']:
      ensure  => stopped,
      enable  => false,
      tag     => "mailservices",
    }
  }

  Package <| tag == 'mailpackages' |> -> Service <| tag == 'mailservices' |>


  service{'rmilter':
    ensure => running,
    enable => true,
    tag    => "mailservices",
  }

  exec {'systemctl-daemon-reload-clamav':
    refreshonly => true,
    command     => '/bin/systemctl daemon-reload',
  }


  if $clamav {
    quick_file_lines{'clamd':
      path    => "/etc/clamav/clamd.conf",
      conf    => {
        'ScanPartialMessages'      => 'true',
        'DetectPUA'                => 'true',
        'MaxThreads'               => '1',
        'StructuredDataDetection'  => 'false',
        'HeuristicScanPrecedence'  => 'false',
      },
      require => Package['clamav-daemon'],
      notify  => Service['clamav-daemon'],
    }
    file{'/etc/systemd/system/clamav-daemon.socket.d/extend.conf':
      content => '[Socket]
  ListenStream=
  SocketUser=clamav
  ListenStream=127.0.0.1:10031
  ',
      notify  => [Exec['systemctl-daemon-reload-clamav'], Service['clamav-daemon']],
    }

    Exec['systemctl-daemon-reload-clamav'] -> Service['clamav-daemon']
  } else {
    file {'/etc/systemd/system/clamav-daemon.socket.d/extend.conf':
      ensure =>  absent,
      notify => Exec['systemctl-daemon-reload-clamav'],
    }
  }

  file{"/etc/rmilter.conf.local":
    content => template('mailserver/rmilter.conf.local.erb'),
    require => [Package['rmilter'], Exec['rmilter-default-conf-back']],
    notify  => Service['rmilter'],
  }
  exec{"rmilter-default-conf-back":
    command => "/bin/mv -f /etc/rmilter.conf.dpkg-dist /etc/rmilter.conf",
    onlyif  => "/usr/bin/test -e /etc/rmilter.conf.dpkg-dist",
  }

  if $redis_servers {
    # TODO(sileht): remove redis conf from here
    package {'redis-server':
      tag => 'mailpackages',
    }
    service {'redis-server':
      ensure => running,
      enable => true,
      tag    => 'mailservices',
    }
    file_line{"redis-bind-all":
      path              => "/etc/redis/redis.conf",
      line              => "bind $ipaddress_eth0",
      match             => "^bind",
      match_for_absence => true,
      after             => '^# ~~~~~~~~~~~~~~',
      notify            => Service['redis-server'],
    }

  }

  $opendkim_domains = keys($opendkim_keys)
  opendkim_key{$opendkim_domains:
    keys => $opendkim_keys
  }

  file{"/etc/rspamd/override.d/": ensure => directory }
  file{"/etc/rspamd/override.d/options.inc":
    content => '
filters = "chartable,dkim,spf,rbl,emails,surbl,regexp,fuzzy_check,ratelimit,phishing,maillist,once_received,forged_recipients,hfilter,ip_score,mime_types,dmarc,spamassassin"
temp_dir = "/dev/shm"
',
    require => Package['rspamd'],
    notify  => Service['rspamd'],
  }

  file{"/etc/rspamd/lua":
    ensure => directory
  }

  quick_files{['main.cf', 'master.cf']:
    path => "/etc/postfix", tpath => "mailserver/postfix-",
    notify  => Service['postfix'],
    require => Package['postfix'],
  }

  exec{'/usr/sbin/postmap /etc/postfix/transport':
    refreshonly => true,
    subscribe => File['/etc/postfix/transport'],
    notify  => Service['postfix'],
    require => Package['postfix'],
  }

  file{'/etc/mailname':
    content => $domains[0],
  }

  file{$virtual_aliases_file_path:
    content => $aliases,
    notify  => Service['postfix'],
    require => Package['postfix'],
  }

  exec{"/usr/sbin/postmap $virtual_aliases_file_path":
    refreshonly => true,
    subscribe => File[$virtual_aliases_file_path],
    creates => "${virtual_aliases_file_path}.db",
    require => Package['postfix'],
    notify  => Service['postfix'],
  }

  file{'/etc/postfix/transport':
    content => $transports,
    notify  => Service['postfix'],
    require => Package['postfix'],
  }

  $postmap_files = keys($all_postmap_datas)
  quick_postmap_files{$postmap_files: datas => $all_postmap_datas}

  file_line{'dovecot-auth':
    path => '/etc/dovecot/conf.d/10-auth.conf',
    match => "!include auth-system.conf.ext",
    line => "#!include auth-system.conf.ext",
    notify => Service['dovecot'],
    require => Package['dovecot-core'],
  }

  quick_files{'local.conf':
    path => "/etc/dovecot",
    tpath => 'mailserver/dovecot-',
    notify => Service['dovecot'],
    require => Package['dovecot-core'],
  }

  file{'/etc/dovecot/account.db':
    content => $accounts,
    notify => Service['dovecot'],
    require => Package['dovecot-core'],
  }
  file{'/etc/sudoers.d/dovecot':
    content => "vmail   ALL= (debian-spamd) NOPASSWD: /etc/dovecot/sa-learn-pipe.sh
",
  }

  package{['solr-jetty', 'jetty9']:
    ensure => purged,
  }
  if $use_solr_indexer {
    package{['solr-tomcat', 'tomcat8', 'dovecot-solr']:
      notify => Service['dovecot'],
      require => Package['dovecot-core'],
    }
    service{'tomcat8':
      ensure => running,
      require => [Package['tomcat8'], Package['dovecot-solr'], Package['solr-tomcat']],
    }
    file{"/etc/solr/conf/schema.xml":
      ensure => "/usr/share/dovecot/solr-schema.xml",
      notify => Service['tomcat8'],
      require => [Package['tomcat8'], Package['dovecot-solr'], Package['solr-tomcat']],
    }

    cron{'solr-optimize':
      command => "curl -s http://localhost:8080/solr/update?optimize=true > /dev/null",
      hour => "0",
    }
    cron{'solr-commit':
      command => "curl -s http://localhost:8080/solr/update?commit=true > /dev/null",
    }
  } else {
    package{['solr-tomcat', 'dovecot-solr']:
      ensure => purged,
    }
  }

}

define quick_postmap_files($datas){
  $data = $datas[$name]
  file{"/etc/postfix/$name":
    content => $data,
    notify  => Service['postfix'],
    require  => Package['postfix'],
  }

  exec{"/usr/sbin/postmap /etc/postfix/$name":
    refreshonly => true,
    subscribe => File["/etc/postfix/$name"],
    creates => "/etc/postfix/${name}.db",
    notify  => Service['postfix'],
  }
}

define quick_files($path, $tpath){
  file{"$path/$name":
    content => template("${tpath}${name}.erb"),
  }
}

define quick_file_lines($path, $conf, $sep=' ', $quote=''){
  $names = prefix(keys($conf), "$name-")
  quick_file_line{$names:
    path   => $path,
    prefix => $name,
    conf   => $conf,
    sep    => $sep,
  }
}

define quick_file_line($path, $prefix, $conf, $sep=' ', $quote=''){
  $match = delete($name, "$prefix-")
  $value = $conf[$match]
  file_line{$name:
    path  => $path,
    match => "^$match$sep",
    line  => "$match$sep$quote$value$quote",
  }
}


define opendkim_key($keys){
  ensure_resource('file', '/etc/dkim', {
    'ensure' => directory,
    'owner' => 'root',
    'group' => 'root',
    'mode' => '0755',
  })

  file{"/etc/dkim/${name}.dkim.key":
    ensure => present,
    content => $keys[$name],
    owner => '_rmilter',
    group => '_rmilter',
    mode => '0640',
    require => [File['/etc/dkim'], Package['rmilter']],
    notify => Service['rmilter'],
  }
}


define validate_rmilter_recipients_whitelist(){
  validate_legacy("String", "validate_re", $name, ['^.*@.*\..*'])
}
