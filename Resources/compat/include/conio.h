// codenv:Windows 的 conio.h(Mac 沒有),讓老師給的程式不用改也能跑
// getch()  :按一個鍵就讀進來,不用按 Enter,螢幕上不會顯示
// getche() :跟 getch() 一樣,但會顯示按的鍵
// kbhit()  :有沒有按鍵在等著被讀(不會停下來等)
// clrscr() :清除畫面
// 方向鍵這類特殊鍵在 Mac 上送出的是好幾個字元,跟 Windows 的 224 + 代碼不一樣
#pragma once
#include <cstdio>
#include <termios.h>
#include <unistd.h>
#include <sys/select.h>

namespace codenv_conio {
// 暫時把終端機改成「按一個鍵就送出、不顯示」,讀完再改回來
inline int read_key(bool echo) {
	std::fflush(stdout);
	termios old_mode;
	if (tcgetattr(STDIN_FILENO, &old_mode) != 0) {
		return std::getchar();
	}
	termios raw = old_mode;
	raw.c_lflag &= ~(ICANON | ECHO);
	raw.c_cc[VMIN] = 1;
	raw.c_cc[VTIME] = 0;
	tcsetattr(STDIN_FILENO, TCSANOW, &raw);
	// 直接從鍵盤讀,不經過 cin / scanf 的緩衝區:跟 Windows 一樣,前面 cin >> 留下的 Enter 不會被讀到
	unsigned char ch;
	int c = read(STDIN_FILENO, &ch, 1) == 1 ? ch : EOF;
	tcsetattr(STDIN_FILENO, TCSANOW, &old_mode);
	if (echo && c != EOF) {
		std::putchar(c);
		std::fflush(stdout);
	}
	// Windows 的 Enter 是 '\r'
	return c == '\n' ? '\r' : c;
}
}

inline int getch() { return codenv_conio::read_key(false); }
inline int getche() { return codenv_conio::read_key(true); }
inline int _getch() { return getch(); }
inline int _getche() { return getche(); }

inline int kbhit() {
	termios old_mode;
	if (tcgetattr(STDIN_FILENO, &old_mode) != 0) {
		return 0;
	}
	termios raw = old_mode;
	raw.c_lflag &= ~(ICANON | ECHO);
	tcsetattr(STDIN_FILENO, TCSANOW, &raw);
	fd_set fds;
	FD_ZERO(&fds);
	FD_SET(STDIN_FILENO, &fds);
	timeval no_wait = {0, 0};
	int ready = select(STDIN_FILENO + 1, &fds, nullptr, nullptr, &no_wait);
	tcsetattr(STDIN_FILENO, TCSANOW, &old_mode);
	return ready > 0;
}
inline int _kbhit() { return kbhit(); }

inline void clrscr() {
	std::fputs("\033[H\033[2J", stdout);
	std::fflush(stdout);
}
