defmodule Badge.Pong.PhysicsTest do
  use ExUnit.Case, async: true

  alias Badge.Pong.Physics
  alias Badge.Theme

  @fp 256

  defp ball(x, y, vx, vy), do: %{x: x * @fp, y: y * @fp, vx: vx, vy: vy}

  test "the court is the screen below the title bar" do
    assert Physics.height() == Theme.height() - Theme.content_top()
    assert Physics.width() == Theme.width()
  end

  describe "step/3" do
    test "moves by velocity times elapsed ms" do
      assert %{x: x, y: y} = Physics.step(ball(100, 100, 256, -256), 10, 0)
      assert {Physics.px(x), Physics.px(y)} == {110, 90}
    end

    test "bounces off the side walls" do
      assert %{vx: vx} = Physics.step(ball(1, 100, -512, -10), 10, 0)
      assert vx == 512

      right = Physics.width() - Physics.ball_size() - 1
      assert %{vx: -512} = Physics.step(ball(right, 100, 512, -10), 10, 0)
    end

    test "the paddle sends the ball back up, faster" do
      paddle = 100 * @fp
      y = Physics.paddle_y() - Physics.ball_size() - 1
      bounced = Physics.step(ball(120, y, 0, 40), 10, paddle)

      assert bounced.vy < -40
      assert Physics.px(bounced.y) == Physics.paddle_y() - Physics.ball_size()
    end

    test "where it strikes the paddle sets the angle" do
      paddle = 100 * @fp
      y = Physics.paddle_y() - Physics.ball_size() - 1

      assert Physics.step(ball(100, y, 0, 40), 10, paddle).vx < 0
      assert Physics.step(ball(140, y, 0, 40), 10, paddle).vx > 0
    end

    test "never exceeds the speed cap" do
      paddle = 100 * @fp
      y = Physics.paddle_y() - Physics.ball_size() - 1
      max = Physics.max_vy()

      assert Physics.step(ball(120, y, 0, max), 10, paddle).vy == -max
    end

    test "a fast ball cannot pass through the paddle in one long step" do
      paddle = 100 * @fp
      y = Physics.paddle_y() - Physics.ball_size() - 1

      assert %{vy: vy} = Physics.step(ball(120, y, 0, Physics.max_vy()), 100, paddle)
      assert vy < 0
    end

    test "a ball past the paddle is missed" do
      y = Physics.height() - 1

      assert Physics.step(ball(10, y, 0, 40), 10, 200 * @fp) == :missed
    end
  end

  describe "move_paddle/3" do
    test "glides and stops at the walls" do
      home = Physics.paddle_home()

      assert Physics.move_paddle(home, 1, 10) > home
      assert Physics.move_paddle(home, -1, 10) < home
      assert Physics.move_paddle(home, 0, 10) == home
      assert Physics.move_paddle(0, -1, 100) == 0

      far = (Physics.width() - Physics.paddle_w()) * @fp
      assert Physics.move_paddle(far, 1, 100) == far
    end
  end

  describe "the handoff" do
    test "is due once the ball will reach the top edge within the lead time" do
      assert Physics.due?(ball(100, 5, 0, -40))
      refute Physics.due?(ball(100, 150, 0, -40))
      refute Physics.due?(ball(100, 5, 0, 40))
    end

    test "a ball leaving one badge enters the other mirrored, above its top edge" do
      sent = Physics.outgoing(ball(10, 5, 30, -40))
      arrived = Physics.incoming(sent)

      assert Physics.px(arrived.x) == Physics.width() - Physics.ball_size() - 10
      assert arrived.vx == -30
      assert arrived.vy == 40
      assert arrived.y < 0
    end

    test "a ball parked in the gap enters at the top at once" do
      parked = Physics.park(ball(10, -500, 0, -40))
      arrived = Physics.incoming(Physics.outgoing(parked))

      assert Physics.px(parked.y) == -Physics.gap()
      assert arrived.y == 0
    end

    test "the cap keeps the gap crossing longer than a resend" do
      assert div(Physics.gap() * @fp, Physics.max_vy()) >= 250
    end

    test "above? is true once the ball has wholly left the screen" do
      assert Physics.above?(ball(10, -Physics.ball_size(), 0, -40))
      refute Physics.above?(ball(10, -1, 0, -40))
    end
  end
end
