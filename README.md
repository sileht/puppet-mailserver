# puppet-mailserver

This module configure a redondant mailserver with:

* dovecot (with dsync)
* postfix
* rspamd

These softwares are configured to work together, the following stuffs are enabled by default:

* ssl required for imap
* ssl used if possible for postfix with dane support
* spf, opendkim, opendmarc enabled for rspamd
* optional solr indexer for dovecot (for use with full text search in roundcube)
* dovecot dsync setup use shared password over ssl tcp connection

## Setup Requirements 

This module depends on puppetlabs-apt and puppetlabs-stdlib modules

## Usage

An example of hiera configuration can be found in examples/ directory

The script puppet.sh can be used to apply the hiera configuration without puppetmaster.


## Example of expected DNS configuration for example.net/


    @           IN MX 10 mx1
    @           IN MX 90 mx2
    @           IN TXT "v=spf1 mx ip4:203.0.113.1 ip4:203.0.113.2 ip6:2001:db8::1/56 ip6:2001:db8::2/56 ptr:example.net ~all
    dkim._domainkey     IN TXT "v=DKIM1; k=rsa; p=MIGfMA0GCSqGSIb3DQEBAQUAA4GNADCBiQKBgQDYWDu7SIqyNar57tlb3d3tHQ5tL/HY07Jf4VtukHQgPugwohQOiP/X0U/B61T9Sef2vQ/pHQiquruRKnqBbxsQavOCXRbhZqGvZOcoLOSXm73hKnc/a3YF674RU5vCfATZNSyGFRzy7RJhg7os3Y8xSUmigpIfYz9t6+HtIqf75wIDAQAB"
    _dmarc              IN TXT "v=DMARC1; p=none; rua=mailto:postmaster@example.net"

    _25._tcp            IN CNAME _tlsa
    _25._tcp.mx1        IN CNAME _tlsa
    _25._tcp.mx2        IN CNAME _tlsa

    _tlsa IN TLSA 3 0 1 0acad0f9a31e70b71833524ff7b33414f5473a6558b2975fba3392c7a6871478
    _tlsa IN TLSA 3 1 1 d773356e016f2df8a7cae46fa25cf9f40922db48e0472e40a1e7e15c2e388779

## Various keys generation

### Opendkim private key and DNS record

    opendkim-genkey --domain=example.net --selector=dkim --verbose


### TLSA dns record

    tlsa --create mx1.sileht.net --ca-cert /etc/ssl/public/wildcard.sileht.net.crt --certificate /etc/ssl/private/wildcard.sileht.net.pem --selector 0 | sed 's/^443/25/'
    tlsa --create mx1.sileht.net --ca-cert /etc/ssl/public/wildcard.sileht.net.crt --certificate /etc/ssl/private/wildcard.sileht.net.pem --selector 1 | sed 's/^443/25/'

## Limitations

Only tested on Debian Jessie

## License

This module is licensed with Apache 2.0
