library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity slot_timing is
port (
    clock           : in  std_logic;
    reset           : in  std_logic;
    
    -- Cartridge pins
    PHI2            : in  std_logic;
    BA              : in  std_logic;

    serve_vic       : in  std_logic;
    serve_enable    : in  std_logic;
    serve_inhibit   : in  std_logic;

    timing_addr     : in  unsigned(2 downto 0) := "000";
    edge_recover    : in  std_logic;
    
    allow_serve     : out std_logic;

    phi2_tick       : out std_logic;
    phi2_fall       : out std_logic;
    phi2_recovered  : out std_logic;
    clock_det       : out std_logic;
    vic_cycle       : out std_logic;    

    refr_inhibit    : out std_logic;
    reqs_inhibit    : out std_logic;
    clear_inhibit   : in  std_logic;
    
    do_sample_addr  : out std_logic;
    do_probe_end    : out std_logic;
    do_sample_io    : out std_logic;
    do_io_event     : out std_logic );
end slot_timing;

architecture gideon of slot_timing is
    signal phi2_c       : std_logic;
    signal phi2_d       : std_logic;
    signal ba_c         : std_logic;
    signal phase_h      : integer range 0 to 127 := 0;
    signal phase_l      : integer range 0 to 127 := 0;
    signal allow_tick_h : boolean := true;
    signal allow_tick_l : boolean := true;
    signal phi2_falling : std_logic;
    signal ba_hist      : std_logic_vector(3 downto 0) := (others => '0');
    signal phi2_rec_i   : std_logic := '0';
    
    signal phi2_tick_i  : std_logic;
    signal serve_en_i   : std_logic := '0';
    signal vic_cycle_i  : std_logic := '0';
    signal off_cnt      : integer range 0 to 7;

    constant c_memdelay    : integer := 5;
    
    -- constant c_probe_end   : integer := 11; -- was 11: 220 ns
    -- constant c_sample_vic  : integer := 10; -- was 10: 200 ns
    -- constant c_io          : integer := 19; -- was 19: 380 ns!

    constant c_probe_end   : integer := 14; -- 224 ns
    constant c_sample_vic  : integer := 12; -- 192 ns
    constant c_io          : integer := 24; -- 384 ns!
    
    attribute register_duplication : string;
    attribute register_duplication of ba_c    : signal is "no";
    attribute register_duplication of phi2_c  : signal is "no";
    -- Altera attributes
    attribute dont_replicate           : boolean;
    attribute dont_replicate of ba_c   : signal is true;
    attribute dont_replicate of phi2_c : signal is true;

    attribute dont_retime           : boolean;
    attribute dont_retime of ba_c   : signal is true;
    attribute dont_retime of phi2_c : signal is true;
begin
    vic_cycle_i    <= '1' when (ba_hist = "0000") else '0';
    vic_cycle      <= vic_cycle_i;
    phi2_recovered <= phi2_rec_i;
    phi2_tick      <= phi2_tick_i;
    phi2_fall      <= phi2_d and not phi2_c;
    
    process(clock)
    begin
        if rising_edge(clock) then
            ba_c        <= BA;
            phi2_c      <= PHI2;
            phi2_d      <= phi2_c;
            phi2_tick_i <= '0';
            
            -- Off counter, to allow software to gracefully quit
            if serve_enable='1' and serve_inhibit='0' then
                off_cnt <= 7;
                serve_en_i <= '1';
            elsif off_cnt = 0 then
                serve_en_i <= '0';
            elsif phi2_tick_i='1' and ba_c='1' then
                off_cnt <= off_cnt - 1;
                serve_en_i <= '1';
            end if;

            -- related to rising edge
            if ((edge_recover = '1') and (phase_l = 31)) or 
               ((edge_recover = '0') and phi2_d='0' and phi2_c='1' and allow_tick_h) then
                ba_hist      <= ba_hist(2 downto 0) & ba_c;
                phi2_tick_i  <= '1';
                phi2_rec_i   <= '1';
                phase_h      <= 0;
                reqs_inhibit <= serve_en_i;
                clock_det    <= '1';
                allow_tick_h <= false; -- filter
            elsif phase_h = 127 then
                clock_det <= '0';
                refr_inhibit <= '0';
            else                            
                phase_h   <= phase_h + 1;
            end if;
            if phase_h = 56 then
                allow_tick_h <= true;
            end if;

            -- related to falling edge
            phi2_falling <= '0';
            if phi2_d='1' and phi2_c='0' and allow_tick_l then  -- falling edge
                phi2_falling <= '1';
                phi2_rec_i   <= '0';
                phase_l      <= 0;
                allow_tick_l <= false; -- filter
            elsif phase_l /= 127 then
                phase_l <= phase_l + 1;
            end if;
            if phase_l = 56 then
                allow_tick_l <= true;
            end if;

            do_io_event <= phi2_falling;

            -- timing pulses
            do_sample_addr <= '0';
            if (vic_cycle_i = '0' and phase_h = timing_addr) or 
               (vic_cycle_i = '1' and phase_h = c_sample_vic - 1) then
                do_sample_addr <= '1';
            end if;

            if serve_vic = '1' and serve_en_i = '1' then
                if phase_l = (c_sample_vic - c_memdelay) then
                    reqs_inhibit <= '1';
                elsif phase_l = (c_sample_vic - 1) then
                    do_sample_addr <= '1';            
                end if;
            end if;
            
            if clear_inhibit='1' then
                reqs_inhibit <= '0';
            end if;
            
            if phase_l = 25 or phase_h = 25 then
                refr_inhibit <= '1'; -- doesn't matter if serve is on or off, refresh can always be in cadence with PHI2
            elsif clear_inhibit = '1' then
                refr_inhibit <= '0';
            end if;   

            do_probe_end <= '0';            
            if phase_h = c_probe_end then
                do_probe_end <= '1';
            end if;

            do_sample_io <= '0';
            if phase_h = c_io - 1 then
                do_sample_io <= '1';
            end if;

            if reset='1' then
                allow_tick_h <= true;
                allow_tick_l <= true;
                phase_h      <= 127;
                phase_l      <= 127;
                refr_inhibit <= '0';
                reqs_inhibit <= '0';
                clock_det    <= '0';
            end if;
        end if;
    end process;
    
    allow_serve <= serve_en_i;
end gideon;
