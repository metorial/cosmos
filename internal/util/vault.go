package util

import (
	"crypto/tls"
	"crypto/x509"
	"encoding/pem"
	"fmt"
	"os"
	"time"

	vault "github.com/hashicorp/vault/api"
	log "github.com/sirupsen/logrus"
)

type VaultCertManager struct {
	client   *vault.Client
	pkiPath  string
	role     string
	hostname string
	certPath string
	keyPath  string
	caPath   string
	ttl      string
}

type VaultCertConfig struct {
	VaultAddr  string
	VaultToken string
	PKIPath    string
	Role       string
	CertPath   string
	KeyPath    string
	CAPath     string
	TTL        string
}

type TLSConfigWrapper struct {
	Config    *tls.Config
	CertMgr   *VaultCertManager
	RenewTime time.Duration
}

func NewVaultCertManager(config *VaultCertConfig) (*VaultCertManager, error) {
	vaultConfig := vault.DefaultConfig()
	vaultConfig.Address = config.VaultAddr

	client, err := vault.NewClient(vaultConfig)
	if err != nil {
		return nil, fmt.Errorf("failed to create vault client: %w", err)
	}

	client.SetToken(config.VaultToken)

	hostname, err := os.Hostname()
	if err != nil {
		return nil, fmt.Errorf("failed to get hostname: %w", err)
	}

	return &VaultCertManager{
		client:   client,
		pkiPath:  config.PKIPath,
		role:     config.Role,
		hostname: hostname,
		certPath: config.CertPath,
		keyPath:  config.KeyPath,
		caPath:   config.CAPath,
		ttl:      config.TTL,
	}, nil
}

func (v *VaultCertManager) ObtainCertificate() error {
	log.WithFields(log.Fields{
		"hostname": v.hostname,
		"role":     v.role,
		"ttl":      v.ttl,
	}).Info("Requesting certificate from Vault")

	secret, err := v.client.Logical().Write(
		fmt.Sprintf("%s/issue/%s", v.pkiPath, v.role),
		map[string]interface{}{
			"common_name": v.hostname,
			"ttl":         v.ttl,
		},
	)
	if err != nil {
		return fmt.Errorf("failed to issue certificate: %w", err)
	}

	cert := secret.Data["certificate"].(string)
	key := secret.Data["private_key"].(string)
	ca := secret.Data["issuing_ca"].(string)

	if err := os.WriteFile(v.certPath, []byte(cert), 0644); err != nil {
		return fmt.Errorf("failed to write certificate: %w", err)
	}

	if err := os.WriteFile(v.keyPath, []byte(key), 0400); err != nil {
		return fmt.Errorf("failed to write private key: %w", err)
	}

	if err := os.WriteFile(v.caPath, []byte(ca), 0644); err != nil {
		return fmt.Errorf("failed to write CA certificate: %w", err)
	}

	log.Info("Certificate obtained and saved successfully")
	return nil
}

func (v *VaultCertManager) ShouldRenew(renewBefore time.Duration) (bool, error) {
	certPEM, err := os.ReadFile(v.certPath)
	if err != nil {
		if os.IsNotExist(err) {
			return true, nil
		}
		return false, fmt.Errorf("failed to read certificate: %w", err)
	}

	cert, err := parseCertificate(certPEM)
	if err != nil {
		return true, nil
	}

	timeUntilExpiry := time.Until(cert.NotAfter)
	shouldRenew := timeUntilExpiry < renewBefore

	if shouldRenew {
		log.WithFields(log.Fields{
			"expires_in":   timeUntilExpiry,
			"renew_before": renewBefore,
		}).Info("Certificate renewal needed")
	}

	return shouldRenew, nil
}

func (v *VaultCertManager) RenewCertificate() error {
	log.Info("Renewing certificate")

	tmpCertPath := v.certPath + ".tmp"
	tmpKeyPath := v.keyPath + ".tmp"

	secret, err := v.client.Logical().Write(
		fmt.Sprintf("%s/issue/%s", v.pkiPath, v.role),
		map[string]interface{}{
			"common_name": v.hostname,
			"ttl":         v.ttl,
		},
	)
	if err != nil {
		return fmt.Errorf("failed to renew certificate: %w", err)
	}

	cert := secret.Data["certificate"].(string)
	key := secret.Data["private_key"].(string)

	if err := os.WriteFile(tmpCertPath, []byte(cert), 0644); err != nil {
		return fmt.Errorf("failed to write temporary certificate: %w", err)
	}

	if err := os.WriteFile(tmpKeyPath, []byte(key), 0400); err != nil {
		return fmt.Errorf("failed to write temporary private key: %w", err)
	}

	if err := os.Rename(tmpCertPath, v.certPath); err != nil {
		return fmt.Errorf("failed to replace certificate: %w", err)
	}

	if err := os.Rename(tmpKeyPath, v.keyPath); err != nil {
		return fmt.Errorf("failed to replace private key: %w", err)
	}

	log.Info("Certificate renewed successfully")
	return nil
}

func (v *VaultCertManager) LoadTLSConfig() (*tls.Config, error) {
	cert, err := tls.LoadX509KeyPair(v.certPath, v.keyPath)
	if err != nil {
		return nil, fmt.Errorf("failed to load certificate pair: %w", err)
	}

	caCert, err := os.ReadFile(v.caPath)
	if err != nil {
		return nil, fmt.Errorf("failed to read CA certificate: %w", err)
	}

	caCertPool := x509.NewCertPool()
	if !caCertPool.AppendCertsFromPEM(caCert) {
		return nil, fmt.Errorf("failed to append CA certificate")
	}

	return &tls.Config{
		Certificates: []tls.Certificate{cert},
		RootCAs:      caCertPool,
		ClientCAs:    caCertPool,
		MinVersion:   tls.VersionTLS12,
	}, nil
}

func parseCertificate(certPEM []byte) (*x509.Certificate, error) {
	block, _ := pem.Decode(certPEM)
	if block == nil {
		return nil, fmt.Errorf("failed to decode PEM block")
	}

	cert, err := x509.ParseCertificate(block.Bytes)
	if err != nil {
		return nil, fmt.Errorf("failed to parse certificate: %w", err)
	}

	return cert, nil
}

func LoadTLSConfigFromFiles(certPath, keyPath, caPath string) (*tls.Config, error) {
	cert, err := tls.LoadX509KeyPair(certPath, keyPath)
	if err != nil {
		return nil, fmt.Errorf("failed to load certificate pair: %w", err)
	}

	caCert, err := os.ReadFile(caPath)
	if err != nil {
		return nil, fmt.Errorf("failed to read CA certificate: %w", err)
	}

	caCertPool := x509.NewCertPool()
	if !caCertPool.AppendCertsFromPEM(caCert) {
		return nil, fmt.Errorf("failed to append CA certificate")
	}

	return &tls.Config{
		Certificates: []tls.Certificate{cert},
		RootCAs:      caCertPool,
		ClientCAs:    caCertPool,
		MinVersion:   tls.VersionTLS12,
	}, nil
}
