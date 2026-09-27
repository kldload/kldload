package main

import (
	"strings"
	"testing"

	"github.com/charmbracelet/bubbles/textinput"
	tea "github.com/charmbracelet/bubbletea"
)

// press drives installModel.Update the way the terminal does.
func press(t *testing.T, m installModel, keys ...string) installModel {
	t.Helper()
	for _, k := range keys {
		var msg tea.KeyMsg
		switch k {
		case "enter":
			msg = tea.KeyMsg{Type: tea.KeyEnter}
		case "esc":
			msg = tea.KeyMsg{Type: tea.KeyEsc}
		default:
			msg = tea.KeyMsg{Type: tea.KeyRunes, Runes: []rune(k)}
		}
		next, _ := m.Update(msg)
		m = next.(installModel)
	}
	return m
}

// atPassword is an encrypted install waiting at the password prompt.
func atPassword(t *testing.T) installModel {
	t.Helper()
	m := installModel{input: textinput.New(), security: "encrypted", username: "admin"}
	m.step = stPassword
	m.startText("", "", true)
	return m
}

// The ZFS passphrase is asked twice, like the password. Before 2026-09-27 it
// was asked once and a typo installed a pool nobody could unlock.
func TestInstallPassphraseConfirmed(t *testing.T) {
	m := press(t, atPassword(t), "pw12", "enter", "pw12", "enter")
	if m.step != stPassphrase {
		t.Fatalf("after the password pair: step %d, want stPassphrase", m.step)
	}
	m = press(t, m, "right horse", "enter")
	if m.step != stPassphrase2 {
		t.Fatalf("after one passphrase: step %d, want stPassphrase2 (asked again)", m.step)
	}
	m = press(t, m, "right horsf", "enter")
	if m.step != stPassphrase || m.passph != "" || m.err == "" {
		t.Fatalf("mismatch: step %d passph %q err %q, want back at stPassphrase, cleared, with an error", m.step, m.passph, m.err)
	}
	m = press(t, m, " x\"y $z ", "enter", " x\"y $z ", "enter")
	if m.step != stSummary {
		t.Fatalf("matching pair: step %d, want stSummary", m.step)
	}
	if !strings.Contains(m.answers(), "KLDLOAD_ZFS_PASSPHRASE=\" x\"y $z \"\n") {
		t.Fatalf("passphrase not written as typed:\n%s", m.answers())
	}
	// esc from the summary re-asks the passphrase, never lands on "again"
	if m = press(t, m, "esc"); m.step != stPassphrase {
		t.Fatalf("esc from summary: step %d, want stPassphrase", m.step)
	}
}

// Unencrypted: no passphrase is asked, and esc from the summary goes back to
// the password, not to a passphrase prompt that does not apply.
func TestInstallUnencryptedSkipsPassphrase(t *testing.T) {
	m := atPassword(t)
	m.security = "standard"
	m = press(t, m, "pw12", "enter", "pw12", "enter")
	if m.step != stSummary {
		t.Fatalf("step %d, want stSummary", m.step)
	}
	if strings.Contains(m.answers(), "PASSPHRASE") {
		t.Fatalf("unencrypted answers carry a passphrase:\n%s", m.answers())
	}
	if m = press(t, m, "esc"); m.step != stPassword {
		t.Fatalf("esc from summary: step %d, want stPassword", m.step)
	}
}
