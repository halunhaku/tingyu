package sources

// Credential storage: macOS Keychain only, one key per source (plan §3.4).
//
// Choice of implementation: mygo.Secrets, which is the same Security.framework
// generic-password API through purego — no cgo, so the CGO_ENABLED=0 rule holds,
// and no secret ever passes through a command line where `ps` could show it
// (the `security` CLI alternative would). The service name is fixed instead of
// the app identifier so the acceptance harness and tests address the same
// items as the app.
//
// mygo.Secrets caps one item at 2560 bytes (the Windows Credential Manager's
// limit, which mygo applies everywhere). A Quark Cookie can exceed that, so
// values are sharded under `<key>#0..#n-1` with a manifest in `<key>`;
// the shard size leaves headroom for the manifest sentence and for values that
// grow a little between reads.
//
// No plaintext fallback exists: the Flutter client had a 0600 file for unsigned
// development builds, and plan §2.1 #7 drops it for this stack.

import (
	"errors"
	"fmt"
	"strconv"
	"strings"
	"sync/atomic"

	"github.com/egoist/mygo"
)

// DefaultKeychainService is the Keychain service of the Go client.
const DefaultKeychainService = "com.halunhaku.tingyu.sources"

// secretChunkSize is the largest value stored in one Keychain item. It is
// below mygo.MaxSecretSize (2560) on purpose: the manifest line and a BOM-free
// re-encode still fit.
const secretChunkSize = 2400

// manifestPrefix marks a stored value as a shard manifest.
const manifestPrefix = "tingyu-shards:"

// SecretStore is the small surface of a credential store. Values are bytes so
// a Cookie is stored verbatim (parsing happens after the read).
type SecretStore interface {
	// Get returns the value and whether it exists.
	Get(key string) ([]byte, bool, error)
	Set(key string, value []byte) error
	Delete(key string) error
}

// Keychain is the login Keychain of the user, addressed through mygo.Secrets.
type Keychain struct {
	// Service overrides DefaultKeychainService (tests use a throwaway one).
	Service string
}

func (k Keychain) service() string {
	if strings.TrimSpace(k.Service) != "" {
		return k.Service
	}
	return DefaultKeychainService
}

// Get returns the secret under key, joining shards when it was split.
func (k Keychain) Get(key string) ([]byte, bool, error) {
	module := mygo.Secrets.Service(k.service())
	raw, err := module.Get(key)
	if errors.Is(err, mygo.ErrSecretNotFound) {
		return nil, false, nil
	}
	if err != nil {
		return nil, false, fmt.Errorf("keychain: read %s: %w", key, err)
	}
	count, sharded := parseManifest(raw)
	if !sharded {
		return raw, true, nil
	}
	joined := make([]byte, 0, len(raw))
	for i := 0; i < count; i++ {
		chunk, chunkErr := module.Get(shardKey(key, i))
		if errors.Is(chunkErr, mygo.ErrSecretNotFound) {
			return nil, false, fmt.Errorf("keychain: %s is missing shard %d of %d", key, i, count)
		}
		if chunkErr != nil {
			return nil, false, fmt.Errorf("keychain: read %s#%d: %w", key, i, chunkErr)
		}
		joined = append(joined, chunk...)
	}
	return joined, true, nil
}

// Set stores value, replacing any earlier value and stale shards.
func (k Keychain) Set(key string, value []byte) error {
	module := mygo.Secrets.Service(k.service())
	// Clear the shards of a previous split value first, so shrinking a Cookie
	// cannot leave an old tail behind that a later read would append.
	previous, err := module.Get(key)
	if err != nil && !errors.Is(err, mygo.ErrSecretNotFound) {
		return fmt.Errorf("keychain: read %s: %w", key, err)
	}
	if count, sharded := parseManifest(previous); sharded {
		for i := 0; i < count; i++ {
			_ = module.Delete(shardKey(key, i))
		}
	}
	if len(value) <= secretChunkSize {
		if err := module.Set(key, value); err != nil {
			return fmt.Errorf("keychain: write %s: %w", key, err)
		}
		return nil
	}
	count := (len(value) + secretChunkSize - 1) / secretChunkSize
	for i := 0; i < count; i++ {
		start := i * secretChunkSize
		end := start + secretChunkSize
		if end > len(value) {
			end = len(value)
		}
		if err := module.Set(shardKey(key, i), value[start:end]); err != nil {
			return fmt.Errorf("keychain: write %s#%d: %w", key, i, err)
		}
	}
	manifest := []byte(manifestPrefix + strconv.Itoa(count))
	if err := module.Set(key, manifest); err != nil {
		return fmt.Errorf("keychain: write %s manifest: %w", key, err)
	}
	return nil
}

// Delete removes the secret and any shards.
func (k Keychain) Delete(key string) error {
	module := mygo.Secrets.Service(k.service())
	if previous, err := module.Get(key); err == nil {
		if count, sharded := parseManifest(previous); sharded {
			for i := 0; i < count; i++ {
				if err := module.Delete(shardKey(key, i)); err != nil && !errors.Is(err, mygo.ErrSecretNotFound) {
					return fmt.Errorf("keychain: delete %s#%d: %w", key, i, err)
				}
			}
		}
	}
	if err := module.Delete(key); err != nil {
		return fmt.Errorf("keychain: delete %s: %w", key, err)
	}
	return nil
}

func shardKey(key string, index int) string {
	return key + "#" + strconv.Itoa(index)
}

// parseManifest recognizes a shard manifest.
func parseManifest(value []byte) (int, bool) {
	text := string(value)
	if !strings.HasPrefix(text, manifestPrefix) {
		return 0, false
	}
	count, err := strconv.Atoi(strings.TrimSpace(strings.TrimPrefix(text, manifestPrefix)))
	if err != nil || count <= 0 {
		return 0, false
	}
	return count, true
}

// MemoryStore is an in-process SecretStore for tests and for acceptance runs
// that must not touch the user's real Keychain. It never writes a file.
type MemoryStore struct {
	values map[string][]byte
}

// NewMemoryStore returns an empty store.
func NewMemoryStore() *MemoryStore {
	return &MemoryStore{values: map[string][]byte{}}
}

func (m *MemoryStore) Get(key string) ([]byte, bool, error) {
	value, ok := m.values[key]
	return value, ok, nil
}

func (m *MemoryStore) Set(key string, value []byte) error {
	if m.values == nil {
		m.values = map[string][]byte{}
	}
	m.values[key] = append([]byte(nil), value...)
	return nil
}

func (m *MemoryStore) Delete(key string) error {
	delete(m.values, key)
	return nil
}

// Credentials is the credential API the rest of M3 uses. It also counts
// writes, so a cached source adapter built with an old password or a revoked
// Cookie is dropped (the Flutter client's credentialEpoch).
type Credentials struct {
	store SecretStore
	epoch atomic.Uint64
}

// NewCredentials wraps a store.
func NewCredentials(store SecretStore) *Credentials {
	if store == nil {
		store = Keychain{}
	}
	return &Credentials{store: store}
}

// Epoch increases on every credential write.
func (c *Credentials) Epoch() uint64 { return c.epoch.Load() }

// Key names are the Flutter client's account names (secure_store.dart's
// accountFor), so a future migration of Keychain items would line up.
func webDAVPasswordKey(sourceID string) string { return "webdav_password_" + sourceID }
func quarkCookieKey(sourceID string) string    { return "quark_cookie_" + sourceID }

// WebDAVPassword returns the stored password and whether it exists.
func (c *Credentials) WebDAVPassword(sourceID string) (string, bool, error) {
	return c.read(webDAVPasswordKey(sourceID))
}

// SetWebDAVPassword stores the password for a source.
func (c *Credentials) SetWebDAVPassword(sourceID, password string) error {
	return c.write(webDAVPasswordKey(sourceID), password)
}

// QuarkCookie returns the stored Cookie header and whether it exists.
func (c *Credentials) QuarkCookie(sourceID string) (string, bool, error) {
	return c.read(quarkCookieKey(sourceID))
}

// SetQuarkCookie stores the Cookie header for a source.
func (c *Credentials) SetQuarkCookie(sourceID, cookie string) error {
	return c.write(quarkCookieKey(sourceID), cookie)
}

// DeleteQuarkCookie removes a source's Cookie (re-login starts clean).
func (c *Credentials) DeleteQuarkCookie(sourceID string) error {
	c.epoch.Add(1)
	return c.store.Delete(quarkCookieKey(sourceID))
}

// DeleteWebDAVPassword removes a source's password.
func (c *Credentials) DeleteWebDAVPassword(sourceID string) error {
	c.epoch.Add(1)
	return c.store.Delete(webDAVPasswordKey(sourceID))
}

func (c *Credentials) read(key string) (string, bool, error) {
	value, found, err := c.store.Get(key)
	if err != nil {
		return "", false, err
	}
	if !found {
		return "", false, nil
	}
	return strings.TrimSpace(string(value)), true, nil
}

func (c *Credentials) write(key, value string) error {
	value = strings.TrimSpace(value)
	if value == "" {
		return errors.New("凭据为空，未写入钥匙串")
	}
	if err := c.store.Set(key, []byte(value)); err != nil {
		return err
	}
	c.epoch.Add(1)
	return nil
}
