
class mailserver (
  $domains,
  $mynetworks,
  $accounts,
  $aliases,
  $doveadm_password,
  $postmaster_address,
  $sync_dest,
  $ssl_ca,
  $ssl_cert,
  $ssl_key,
  $disable_plaintext_auth = true,
  $use_solr_indexer = false,
  $rmilter_recipients_whitelist = [],
  $opendkim_keys = {},
  $postmap_datas = {},
  $postfix_options = {},
  $postfix_dane_enabled = true,
  $virtual_aliases_file_path = "/etc/aliases",
  $relay_domain = undef,
  $transports = "",
){

  validate_array($rmilter_recipients_whitelist)
  validate_rmilter_recipients_whitelist{$rmilter_recipients_whitelist:}
  validate_array($mynetworks)
  validate_mynetworks{$mynetworks:}
  validate_array($domains)
  validate_string($postmaster_address)
  validate_re($postmaster_address, '^.*@.*\..*')
  validate_hash($opendkim_keys)
  validate_hash($postmap_datas)
  validate_hash($postfix_options)
  validate_bool($use_solr_indexer)
  validate_bool($disable_plaintext_auth)
  validate_absolute_path($ssl_ca)
  validate_absolute_path($ssl_cert)
  validate_absolute_path($ssl_key)

  ensure_resource("apt::source", "rspamd", {
    "location" => "http://rspamd.com/apt-stable/",
    "repos" => "main",
    "release" => $::lsbdistcodename,
    "include" => {"src" => false},
    "key" => {
      "id" => "3FA347D5E599BE4595CA2576FFA232EDBF21E25E",
      "source" => "http://rspamd.com/apt/gpg.key",
    }
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
    'clamav-daemon', 'clamav-unofficial-sigs', 'clamdscan',
    'dovecot-imapd', 'dovecot-managesieved', 'dovecot-lmtpd',
    'dovecot-core', 'dovecot-antispam',
    'imapfilter',
    'rspamd', 'redis-server', 'rmilter',
    'opendkim-tools',
    'postfix', 'postfix-pcre',
    'libnet-ident-perl', 'libio-socket-ssl-perl', 'libdbi-perl',
    ]: tag => 'mailpackages'
  }

  Package <| tag == 'mailpackages' |> -> Service <| tag == 'mailservices' |>

  service{[
    'postfix', 'dovecot',
    'rspamd',
    'clamav-daemon', 'clamav-freshclam'
  ]:
    ensure  => running,
    enable  => true,
    tag     => "mailservices",
  }

  service{'rmilter':
    ensure     => running,
    hasrestart => false,  # restart won't work well
    enable     => true,
    tag        => "mailservices",
  }

  quick_file_lines{'clamd':
    path                        => "/etc/clamav/clamd.conf",
    conf                        => {
      'ScanPartialMessages'     => 'true',
      'DetectPUA'               => 'true',
      'MaxThreads'              => '60',
      'StructuredDataDetection' => 'true',
    },
    require => Package['clamav-daemon'],
    notify => Service['clamav-daemon'],
  }


  exec {'systemctl-daemon-reload-clamav':
    refreshonly => true,
    command => '/bin/systemctl daemon-reload',
  }

  file{'/etc/systemd/system/clamav-daemon.socket.d/extend.conf':
    content => '[Socket]
ListenStream=
SocketUser=clamav
ListenStream=127.0.0.1:10031
',
    notify => [Exec['systemctl-daemon-reload-clamav'], Service['clamav-daemon']],
  }

  Exec['systemctl-daemon-reload-clamav'] -> Service['clamav-daemon']


  file{"/etc/rmilter.conf":
    content => template('mailserver/rmilter.conf.erb'),
    require => Package['rmilter'],
    notify  => Service['rmilter'],
  }

  $opendkim_domains = keys($opendkim_keys)
  opendkim_key{$opendkim_domains:
    keys => $opendkim_keys
  }

  file{"/etc/rspamd/override.d/": ensure => directory }
  file{"/etc/rspamd/override.d/options.inc":
    content => '
filters = "chartable,dkim,spf,rbl,emails,surbl,regexp,fuzzy_check,ratelimit,phishing,maillist,once_received,forged_recipients,hfilter,ip_score,mime_types,dmarc"
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

  if $use_solr_indexer {
    package{['solr-jetty', 'jetty8', 'dovecot-solr']:
      notify => Service['dovecot'],
      require => Package['dovecot-core'],
    }
    service{'jetty8':
      ensure => running,
      require => [Package['jetty8'], Package['dovecot-solr'], Package['solr-jetty']],
    }
    quick_file_lines{'jetty8':
      path    => '/etc/default/jetty8',
      conf    => {'NO_START' => '0'},
      notify  => Service['jetty8'],
      sep     => '=',
    }
    file{"/etc/solr/conf/schema.xml":
      ensure => "/usr/share/dovecot/solr-schema.xml",
      notify => Service['jetty8'],
      require => [Package['jetty8'], Package['dovecot-solr'], Package['solr-jetty']],
    }

    cron{'solr-optimize':
      command => "curl -s http://localhost:8080/solr/update?optimize=true > /dev/null",
      hour => "0",
    }
    cron{'solr-commit':
      command => "curl -s http://localhost:8080/solr/update?commit=true > /dev/null",
    }
  } else {
    package{['solr-jetty', 'jetty8', 'dovecot-solr']:
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

define validate_mynetworks(){
    validate_ip_address($name)
}

define validate_rmilter_recipients_whitelist(){
  validate_re($name, '^.*@.*\..*')
}
