fs    = require 'fs'
net   = require 'net'
https = require 'https'
axios = require 'axios'

module.exports = class HealthChecks

    # Setup vulners API key and profile attribute
    constructor: (@config={vulners: null, profiles: {}}) ->

    # Add TLS/SSLV profile
    addProfile: (name, keychain) ->
        try
            @config.profiles[name] = {
                rejectUnauthorized: false
                key: fs.readFileSync keychain.key
                cert: fs.readFileSync keychain.cert
                ca: fs.readFileSync keychain.ca
            }
        catch error
            throw error
        
        return true
    
    isProfileSet: (name) ->
        return @config.profiles[name]?

    # Check if remote port is open
    _checkPort: (host, port) ->
        return new Promise (resolve, reject) =>
            # Check port is reachable
            net_socket = net.Socket()
            now = new Date().getTime()
            onError = () =>
                net_socket.destroy()
                reject Error host

            net_socket.setTimeout(1000)
            .once('error', onError)
            .once('timeout', onError)
            .connect( port, host, () =>
                # Auto close socket
                net_socket.end()
                latency = (new Date().getTime()) - now
                resolve(latency)
            )
    
    # Retrieve remote peer certificate (supporting vhosts)
    _checkHTTPS: (vhost, port, profile_name) ->
        return new Promise (resolve, reject) =>
            config = {
                host: vhost
                port: port
                method: 'get'
                path: '/'
                agent: false
            }
            secure = false

            if profile_name of @config.profiles
                secure = true
                config.key = @config.profiles[profile_name].key
                config.cert = @config.profiles[profile_name].cert
                config.ca = @config.profiles[profile_name].ca

            cert = null
            isAuthorized = false
            req = https.request config, (res) =>
                cert = res.connection.getPeerCertificate()
                isAuthorized = res.connection.authorized
                return resolve { authorized: isAuthorized, certificate: cert }
            .on 'error', (err) =>
                console.error("HTTPS Error: #{err.response.data}")
                return reject(err.response.data)
            
            req.end()

    # Execute web request upon host
    _request: (url, method, data, profile_name, json=false) ->
        if not method.toUpperCase() in ['GET', 'POST', 'PUT', 'DELETE', 'HEAD', 'OPTIONS']
            throw 'Sorry, unsupported method'

        config = {
            url: url
            method: method
            headers: {
                'User-Agent': 'ProHacktive HealthChecks - Check https://github.com/ProHacktive for more infos'
            }
        }

        if profile_name of @config.profiles
            config.httpsAgent = new https.Agent(@config.profiles[profile_name])
            
        if data
            config.data = data
        
        return axios(config)

    # Check if a service port is open
    # Return Boolean()
    checkPortIsOpen: (host, port) ->
        try
            status = await @_checkPort host, port
        catch err
            return false

        return Boolean(status)

    # Check latency of a service port
    # Return Number()
    checkPortLatency: (host, port) ->
        try
            latency = await @_checkPort host, port
        catch err
            return -1
        
        return latency
    
    # Gather remote peer certificate's DN
    checkCertificateDN: (host, port, profile_name=null) ->
        try
            dn = ''
            # cert_infos = @_getCertificate host, port, profile_name
            data = await @_checkHTTPS host, port, profile_name
            # Rebuild DN
            for k, v of data.certificate.subject
                dn += "#{k}=#{v},"
            dn = dn.slice(0, -1)
        catch err
            return new Error(err)

        return dn
    
    # Gather remote peer certificate's issuer
    checkCertificateIssuer: (host, port, profile_name=null) ->
        try
            issuers = []
            dn = ''
            data = await @_checkHTTPS host, port, profile_name
            console.log data
            # Rebuild DN
            for k, v of data.certificate.issuer
                dn += "#{k}=#{v},"
            dn = dn.slice(0, -1)
            # Add issuer to list
            if dn not in issuers
                issuers.push dn
        catch err
            return new Error(err)

        return issuers
    
    # Gather remote peer certificate's expiration date
    checkCertificateExpiration: (host, port, profile_name=null) ->
        try
            data = await @_checkHTTPS host, port, profile_name
            console.log data
        catch err
            return new Error(err)

        return data.certificate.valid_to
    
    # Gather remote peer certificate
    checkRemoteCertificate: (host, port, profile_name=null) ->
        try
            data = await @_checkHTTPS host, port, profile_name
        catch err
            return new Error(err)
        return data.certificate
    
    # Check if remote site has client authentication enforced
    # return boolean()
    checkClientAuthentication: (host, port, profile_name=null) ->
        try
            # Try a connection without profile
            data = await @_checkHTTPS host, port, profile_name
            return data.authorized
        catch err
            console.log "Authentication error: #{err}"
            return true

    # Return result of API call in json
    checkAPICallContent: (url, method, data, profile_name=null) ->
        # Enable JSON flag
        try
            infos = await @_request url, method, data, profile_name, true
        catch err
            return new Error(err)

        return { status: infos.status, data: infos.data }

    # Return result of web page request
    checkWebPageContent: (url, profile_name=null) ->
        try
            infos = await @_request url, 'GET', null
        catch err
            return new Error(err)

        return { status: infos.status, data: infos.data }

    # Retrieve vulnerabilities based on app/version infos
    # Based on vulners.io service (use config for API key)
    checkVulnerabilities: (app, version) ->