#!/usr/bin/env bash

# make our output look nice...
script_name="evilgophish setup"

function check_privs () {
    if [[ "$(whoami)" != root ]]; then
        print_error "You need root privileges to run this script."
        exit 1
    fi
}

function print_good () {
    echo -e "[${script_name}] \x1B[01;32m[+]\x1B[0m $1"
}

function print_error () {
    echo -e "[${script_name}] \x1B[01;31m[-]\x1B[0m $1"
}

function print_warning () {
    echo -e "[${script_name}] \x1B[01;33m[-]\x1B[0m $1"
}

function print_info () {
    echo -e "[${script_name}] \x1B[01;34m[*]\x1B[0m $1"
}

if [[ $# -ne 8 ]]; then
    print_error "Missing Parameters:"
    print_error "Usage:"
    print_error './setup <root domain> <subdomain(s)> <root domain bool> <redirect url> <feed bool> <rid replacement> <blacklist bool>'
    print_error " - root domain                     - the root domain to be used for the campaign"
    print_error " - subdomains                      - a space separated list of subdomains to proxy to evilginx3, can be one if only one"
    print_error " - root domain bool                - true or false to proxy root domain to evilginx3"
    print_error " - redirect url                    - URL to redirect unauthorized Apache requests"
    print_error " - feed bool                       - true or false if you plan to use the live feed"
    print_error " - rid replacement                 - replace the gophish default \"rid\" in phishing URLs with this value"
    print_error " - blacklist bool                  - true or false to use Apache blacklist"
    print_error " - certpath                        - path to LetsEncrypt certificates on the system"
    print_error "Example:"
    print_error '  ./setup.sh example.com "accounts myaccount" false https://redirect.com/ true user_id false /path/to/certs'

    exit 2
fi

# Set variables from parameters
root_domain="${1}"
evilginx3_subs="${2}"
e_root_bool="${3}"
redirect_url="${4}"
feed_bool="${5}"
rid_replacement="${6}"
evilginx_dir=$HOME/.evilginx
bl_bool="${7}"S
certs_path="${8}"

# Install needed dependencies
function install_depends () {
    print_info "Installing dependencies with apt"
    apt-get update
    apt-get install apache2 build-essential letsencrypt certbot wget git net-tools tmux openssl jq -y
    print_good "Installed dependencies with apt!"
    print_info "Installing Go from source"
    v=$(curl -s https://go.dev/dl/?mode=json | jq -r '.[0].version')
    wget https://go.dev/dl/"${v}".linux-amd64.tar.gz
    tar -C /usr/local -xzf "${v}".linux-amd64.tar.gz
    ln -sf /usr/local/go/bin/go /usr/bin/go
    rm "${v}".linux-amd64.tar.gz
    print_good "Installed Go from source!"
}

# Configure Apache
function setup_apache () {
    # Enable needed Apache mods
    print_info "Configuring Apache"
    a2enmod proxy > /dev/null 
    a2enmod proxy_http > /dev/null
    a2enmod proxy_balancer > /dev/null
    a2enmod lbmethod_byrequests > /dev/null
    a2enmod rewrite > /dev/null
    a2enmod ssl > /dev/null

    # Prepare Apache 000-default.conf file
    evilginx3_cstring=""
    for esub in ${evilginx3_subs} ; do
        evilginx3_cstring+=${esub}.${root_domain}
        evilginx3_cstring+=" "
    done
    if [[ $(echo "${e_root_bool}" | grep -ci "true") -gt 0 ]]; then
        evilginx3_cstring+=${root_domain}
    fi
    # Replace template values with user input
    if [[ $(echo "${bl_bool}" | grep -ci "true") -gt 0 ]]; then
        sed "s/ServerAlias evilginx3.template/ServerAlias ${evilginx3_cstring}/g" conf/000-default.conf.template > 000-default.conf
    else 
        sed "s/ServerAlias evilginx3.template/ServerAlias ${evilginx3_cstring}/g" conf/000-default-no-bl.conf.template > 000-default.conf
    fi
    sed -i "s|SSLCertificateFile|SSLCertificateFile ${certs_path}fullchain.pem|g" 000-default.conf    
    sed -i "s|SSLCertificateKeyFile|SSLCertificateKeyFile ${certs_path}privkey.pem|g" 000-default.conf
    # Don't listen on port 80
    sed -i "s|Listen 80||g" /etc/apache2/ports.conf
    # Input redirect information
    sed "s|https://en.wikipedia.org/|${redirect_url}|g" conf/redirect.rules.template > redirect.rules
    # Copy over Apache config file
    cp 000-default.conf /etc/apache2/sites-enabled/
    # Copy over blacklist file if chosen
    if [[ $(echo "${bl_bool}" | grep -ci "true") -gt 0 ]]; then
        cp conf/blacklist.conf /etc/apache2/
    fi
    # Copy over redirect rules file
    cp redirect.rules /etc/apache2/
    rm redirect.rules 000-default.conf
    print_good "Apache configured!"
}

# Configure and install evilginx3
function setup_evilginx3 () {
    # Prepare DNS for evilginx3
    evilginx3_cstring=""
    for esub in ${evilginx3_subs} ; do
        evilginx3_cstring+=${esub}.${root_domain}
        evilginx3_cstring+=" "
    done
    cp /etc/hosts /etc/hosts.bak
    sed -i "s|127.0.0.1.*|127.0.0.1 localhost ${evilginx3_cstring}${root_domain}|g" /etc/hosts
    cp /etc/resolv.conf /etc/resolv.conf.bak
    rm /etc/resolv.conf
    ln -sf /run/systemd/resolve/resolv.conf /etc/resolv.conf
    systemctl stop systemd-resolved
    # Build evilginx3
    cd evilginx3 || exit 1
    go build -o evilginx3
    cd ..
    print_good "Configured evilginx3!"
}

# Configure and install gophish
function setup_gophish () {
    print_info "Configuring gophish"
    # Setup live feed if selected
    if [[ $(echo "${feed_bool}" | grep -ci "true") -gt 0 ]]; then
        sed -i "s|\"feed_enabled\": false,|\"feed_enabled\": true,|g" gophish/config.json
        cd evilfeed || exit 1
        go build
        cd ..
        print_good "Live feed configured! cd into evilfeed then launch binary with ./evilfeed to start!"
    fi
    # Replace rid with user input
    find . -type f -exec sed -i "s|client_id|${rid_replacement}|g" {} \;
    cd gophish || exit 1
    go build
    cd ..
    print_good "Configured gophish!"
}

function main () {
    check_privs
    install_depends
    get_certs_path
    setup_apache
    setup_gophish
    setup_evilginx3
    print_good "Installation complete! When ready start apache with: systemctl restart apache2"
    print_info "It is recommended to run all servers inside a tmux session to avoid losing them over SSH!"
}

main
