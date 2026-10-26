package library

// Favourite writes (plan §6 M1 left them out; M4 showed them as unavailable
// because the kernel had no write path). One row, or a batch in one
// transaction, and every write bumps the row revision so exactly the row that
// changed is rebuilt by the table.

import (
	"context"
	"errors"
	"fmt"

	"github.com/egoist/mygo/plugins/sqlite"
)

// SetFavorite writes the favourite flag of one track.
func (l *Library) SetFavorite(ctx context.Context, id string, favorite bool) error {
	return l.SetFavorites(ctx, []string{id}, favorite)
}

// SetFavorites writes the same favourite value to several tracks in one
// transaction: a batch either lands completely or not at all, and the window
// never shows half a selection.
func (l *Library) SetFavorites(ctx context.Context, ids []string, favorite bool) error {
	if !l.writes {
		return errors.New("library: connection is read-only")
	}
	if len(ids) == 0 {
		return nil
	}
	count := int64(0)
	if favorite {
		count = 1
	}
	statements := make([]sqlite.Statement, 0, len(ids))
	for _, id := range ids {
		statements = append(statements, sqlite.Statement{
			SQL:  `UPDATE tracks SET is_favorite = ? WHERE id = ?`,
			Args: []any{count, id},
		})
	}
	if _, err := l.db.Transaction(ctx, statements); err != nil {
		return fmt.Errorf("library: set favourite: %w", err)
	}
	l.bump(ids...)
	return nil
}
